NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Service = {}
Service.__index = Service

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160) and value:find('%z') == nil
end

local function identifier(value)
    if type(value) == 'number' then return value >= 1 and value == math.floor(value) and value ~= math.huge and value ~= -math.huge end
    return type(value) == 'string' and value:match('^[A-Za-z0-9_.:%-]+$') ~= nil and #value <= 160
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= math.floor(value) or value == math.huge or value == -math.huge then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.REVIEW_INVALID, message, details)
end

local function notFound(result)
    return type(result) == 'table' and result.ok == false and result.error and result.error.code == Codes.REPOSITORY_NOT_FOUND
end

local function actor(service, source)
    if type(service._identity) ~= 'table' or type(service._identity.resolve) ~= 'function' then
        return nil, Result.err(Codes.IDENTITY_UNAVAILABLE, 'review identity service is unavailable')
    end
    local ok, result = pcall(service._identity.resolve, service._identity, source)
    if not ok or type(result) ~= 'table' then return nil, Result.err(Codes.IDENTITY_UNAVAILABLE, 'review identity could not be resolved') end
    if not result.ok or type(result.value) ~= 'table' then return nil, result end
    local identity = result.value
    return { type = 'PLAYER', ref = identity.identityKey or identity.key, source = source, identity = identity }
end

local function safeReview(value)
    if type(value) ~= 'table' then return nil end
    return {
        id = value.id,
        bookingId = value.bookingId or value.booking_id,
        workerProfileId = value.workerProfileId or value.worker_profile_id,
        rating = tonumber(value.rating),
        reviewText = value.reviewText or value.review_text,
        createdAt = value.createdAt or value.created_at
    }
end

function Service.new(options)
    options = options or {}
    local repository = options.repository or options.reviewRepository
    if type(repository) ~= 'table' or type(repository.findByBooking) ~= 'function' or type(repository.create) ~= 'function' then
        return nil, invalid('review service requires a review repository')
    end
    local identity = options.identityService or options.identity
    if type(identity) ~= 'table' or type(identity.resolve) ~= 'function' then return nil, invalid('review service requires an identity service') end
    local booking = options.bookingService or options.booking
    if type(booking) ~= 'table' or type(booking.get) ~= 'function' then return nil, invalid('review service requires a booking service') end
    local config = copy(options.config or NightShift.ReputationConfig or {})
    local reviewConfig = type(config.review) == 'table' and config.review or {}
    local minimum, maximum = integer(reviewConfig.minimum or 1, 1, 5), integer(reviewConfig.maximum or 5, 1, 5)
    if not minimum or not maximum or maximum < minimum then return nil, invalid('review rating bounds are invalid') end
    return setmetatable({
        _repository = repository,
        _identity = identity,
        _booking = booking,
        _clientProfileService = options.clientProfileService or options.clientProfile,
        _clientRepository = options.clientProfileRepository or options.clientRepository,
        _workerService = options.npcWorkerService or options.workerService,
        _workerProfileService = options.workerProfileService,
        _npcProfileRepository = options.npcProfileRepository or options.npcRepository,
        _minimum = minimum, _maximum = maximum,
        _textMaxLength = integer(reviewConfig.textMaxLength or 1000, 0, 2000) or 1000
    }, Service)
end

function Service:_clientProfile(source, identity)
    if type(self._clientProfileService) == 'table' and type(self._clientProfileService.get) == 'function' then
        local result = self._clientProfileService:get(source)
        if type(result) == 'table' and result.ok then return result.value end
        if type(result) == 'table' and notFound(result) then return nil end
        if type(result) == 'table' and result.error then return nil, result end
    end
    if type(self._clientRepository) == 'table' and type(self._clientRepository.findByIdentity) == 'function' then
        local result = self._clientRepository:findByIdentity(identity.playerIdentifier or identity.identifier, identity.characterId)
        if type(result) == 'table' and result.ok then return result.value end
        if type(result) == 'table' and notFound(result) then return nil end
        return nil, result
    end
    return nil, Result.err(Codes.REVIEW_NOT_ELIGIBLE, 'client profile was not found')
end

function Service:_workerProfile(booking)
    if type(booking.workerProfileId) ~= 'nil' and type(self._npcProfileRepository) == 'table' and type(self._npcProfileRepository.findProfileById) == 'function' then
        local result = self._npcProfileRepository:findProfileById(booking.workerProfileId)
        if type(result) == 'table' and result.ok then return result.value end
    end
    if tostring(booking.workerType or ''):upper() == 'NPC' and type(self._workerService) == 'table' and type(self._workerService.get) == 'function' then
        local result = self._workerService:get(booking.workerRef)
        if type(result) == 'table' and result.ok then
            local worker = result.value
            local profile = worker.profile
            if type(profile) == 'table' and profile.id ~= nil and type(self._npcProfileRepository) == 'table' and type(self._npcProfileRepository.findProfileById) == 'function' then
                local persisted = self._npcProfileRepository:findProfileById(profile.id)
                if type(persisted) == 'table' and persisted.ok then return persisted.value end
            end
            return profile
        end
        return nil, result
    end
    if tostring(booking.workerType or ''):upper() == 'PLAYER' and type(self._workerProfileService) == 'table' and type(self._workerProfileService.get) == 'function' and booking.workerSource ~= nil then
        local result = self._workerProfileService:get(booking.workerSource)
        if type(result) == 'table' and result.ok then return result.value end
    end
    return nil, Result.err(Codes.REVIEW_NOT_ELIGIBLE, 'review worker profile was not found')
end

function Service:_aggregate(workerProfile, rating)
    if type(workerProfile) ~= 'table' or type(self._npcProfileRepository) ~= 'table' or type(self._npcProfileRepository.updateProfileExpectedVersion) ~= 'function' then
        return Result.ok({ skipped = true }, { aggregatePending = true })
    end
    local id, version = workerProfile.id, integer(workerProfile.version, 1, 2147483647)
    if not id or not version then return Result.err(Codes.REVIEW_OPERATION_FAILED, 'worker aggregate cannot be versioned') end
    local count = integer(workerProfile.reviewCount or workerProfile.review_count or 0, 0, 2147483647) or 0
    local currentRating = tonumber(workerProfile.rating) or 0
    local nextCount = count + 1
    local nextRating = math.floor((((currentRating * count) + rating) / nextCount) * 100 + 0.5) / 100
    local updated = self._npcProfileRepository:updateProfileExpectedVersion(id, version, { rating = nextRating, reviewCount = nextCount })
    if type(updated) ~= 'table' or not updated.ok then
        return Result.err(Codes.REVIEW_OPERATION_FAILED, 'worker rating aggregate could not be updated', {
            cause = updated and updated.error and updated.error.code,
            reviewCommitted = true
        })
    end
    return Result.ok({ rating = nextRating, reviewCount = nextCount })
end

function Service:submit(source, payload)
    if type(payload) ~= 'table' then return invalid('review payload must be a table') end
    local bookingId = payload.bookingId or payload.booking_id
    if not identifier(bookingId) then return invalid('review booking ID is required') end
    local rating = integer(payload.rating, self._minimum, self._maximum)
    if not rating then return invalid('review rating is outside configured bounds') end
    local reviewText = payload.reviewText or payload.review_text
    if reviewText ~= nil and not text(reviewText, self._textMaxLength) then return invalid('review text is invalid') end
    local currentActor, actorError = actor(self, source)
    if not currentActor then return actorError end
    local bookingResult = self._booking:get(bookingId)
    if type(bookingResult) ~= 'table' or not bookingResult.ok then return bookingResult end
    local booking = bookingResult.value
    if tostring(booking.status or ''):upper() ~= 'SETTLED' then
        return Result.err(Codes.REVIEW_NOT_ELIGIBLE, 'only settled bookings can be reviewed', { status = booking.status })
    end
    if tostring(booking.clientType or ''):upper() ~= 'PLAYER' or tostring(booking.clientRef or '') ~= tostring(currentActor.ref) then
        return Result.err(Codes.REVIEW_NOT_ELIGIBLE, 'review actor does not own the booking')
    end
    if tostring(booking.workerType or ''):upper() ~= 'NPC' then
        return Result.err(Codes.REVIEW_NOT_ELIGIBLE, 'only NPC worker bookings can be reviewed')
    end
    local clientProfile, clientError = self:_clientProfile(source, currentActor.identity)
    if not clientProfile then return clientError or Result.err(Codes.REVIEW_NOT_ELIGIBLE, 'client profile was not found') end
    local workerProfile, workerError = self:_workerProfile(booking)
    if not workerProfile then return workerError or Result.err(Codes.REVIEW_NOT_ELIGIBLE, 'worker profile was not found') end
    local existing = self._repository:findByBooking(booking.id)
    if type(existing) ~= 'table' then return Result.err(Codes.REVIEW_OPERATION_FAILED, 'review lookup returned an invalid result') end
    if existing.ok then return Result.ok({ review = safeReview(existing.value) }, { idempotent = true }) end
    if not notFound(existing) then return existing end
    local created = self._repository:create({
        bookingId = booking.id,
        clientProfileId = clientProfile.id,
        workerProfileId = workerProfile.id,
        rating = rating,
        reviewText = reviewText
    })
    if type(created) ~= 'table' or not created.ok then
        local raced = self._repository:findByBooking(booking.id)
        if type(raced) == 'table' and raced.ok then return Result.ok({ review = safeReview(raced.value) }, { idempotent = true }) end
        return Result.err(Codes.REVIEW_OPERATION_FAILED, 'review could not be persisted', { cause = created and created.error and created.error.code })
    end
    local persisted = self._repository:findByBooking(booking.id)
    local review = persisted and persisted.ok and persisted.value or {
        id = created.value and (created.value.insertId or created.value.id),
        bookingId = booking.id, clientProfileId = clientProfile.id, workerProfileId = workerProfile.id,
        rating = rating, reviewText = reviewText
    }
    local aggregate = self:_aggregate(workerProfile, rating)
    if not aggregate.ok then
        return Result.err(Codes.REVIEW_OPERATION_FAILED, 'review saved but worker aggregate is pending', {
            reviewCommitted = true, cause = aggregate.error and aggregate.error.code
        })
    end
    return Result.ok({ review = safeReview(review), aggregate = aggregate.value }, {
        created = true, serverAuthoritative = true
    })
end

function Service:get(bookingId)
    if not identifier(bookingId) then return invalid('review booking ID is invalid') end
    local result = self._repository:findByBooking(bookingId)
    if type(result) ~= 'table' then return Result.err(Codes.REVIEW_OPERATION_FAILED, 'review lookup returned an invalid result') end
    if not result.ok then
        if notFound(result) then return Result.err(Codes.REVIEW_NOT_FOUND, 'review was not found') end
        return result
    end
    return Result.ok(safeReview(result.value))
end

Service.create = Service.submit
NightShift.ReviewService = Service
