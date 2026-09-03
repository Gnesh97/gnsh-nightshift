export type ApiError = {
  code: string
  message: string
  requestId?: string
}

export type ApiResult<T> =
  | { ok: true; value: T; requestId: string }
  | { ok: false; error: ApiError; requestId: string }

export type WorkerCard = {
  workerId: string
  displayName: string
  initials: string
  district: string
  priceClass: "standard" | "premium"
  startingPrice: number
  rating: number
  ratingCount: number
  availability: "available" | "busy"
  etaMinutes: number
  packages: string[]
}

export type MarketplaceFilters = {
  district?: string
  priceClass?: "standard" | "premium"
}

export type MarketplacePage = {
  items: WorkerCard[]
  total: number
  limit: number
  offset: number
  locations: LocationOption[]
}

export type LocationOption = {
  locationId: string
  label: string
  locationType?: string
  meetingModes: string[]
}

export type BookingDraft = {
  workerId: string
  packageId: string
  meetingMode: "come_to_me" | "pickup" | "meet_there"
  locationId: string
}

export type PriceQuote = {
  quoteId: string
  amount: number
  currency: string
  expiresAt: number | string
  workerId: string
  actionToken?: string
  actionTokenExpiresAt?: number
}

export type BookingConfirmation = {
  bookingId: string
  status: "RESERVED"
  actionToken?: string
  actionTokenExpiresAt?: number
}

export type ClientModeBookingReference = {
  bookingId: string
  status?: ClientBookingStatus
}

export type ClientModeWorkerReference = {
  workerKey: string
  profileKey?: string
  state?: string
  bookingId?: string
}

export type ClientModeLocationReference = {
  locationType: string
  locationRef: string
  meetingMode?: string
}

export type ClientModeReservation = {
  reservationKey: string
  status?: string
}

export type ClientModeDeposit = {
  status: string
  amountMinor?: number
  currency?: string
}

export type ClientModeTravel = {
  travelKey: string
  bookingId: string
  profileKey?: string
  mode?: string
  state?: string
  progress?: number
  etaSeconds?: number
  startedAt?: number
}

export type ClientModeSpawn = {
  travelKey?: string
  bookingId?: string
  profileKey?: string
  generationToken?: string
  spawnKey?: string
  generation?: number
  model?: string
  appearanceProfileRef?: string
  candidate?: { kind: "coords"; x: number; y: number; z: number; heading?: number } | { kind: "provider"; provider: string }
  target?: { kind: "coords"; x: number; y: number; z: number; heading?: number } | { kind: "provider"; provider: string }
  entity?: number
  networkId?: number
  serverOwned?: boolean
  actionToken?: string
}

export type ClientModeSession = {
  bookingId: string
  token: string
  state?: string
  startedAt?: number
  expiresAt?: number
}

export type ClientModeConfirmation = {
  bookingId: string
  status?: ClientBookingStatus
  actionToken?: string
  actionTokenExpiresAt?: number
  booking?: ClientModeBookingReference
  worker?: ClientModeWorkerReference
  location?: ClientModeLocationReference
  reservation?: ClientModeReservation
  deposit?: ClientModeDeposit
}

export type ClientModeTravelResponse = {
  booking?: ClientModeBookingReference
  travel?: ClientModeTravel
  bookingId?: string
  travelKey?: string
  actionToken?: string
  actionTokenExpiresAt?: number
}

export type ClientModeSpawnResponse = ClientModeTravelResponse & {
  spawn?: ClientModeSpawn
  profileKey?: string
  generationToken?: string
  entity?: number
  networkId?: number
}

export type ClientModeArrivalResponse = ClientModeTravelResponse & {
  arrival?: ClientModeTravel
}

export type ClientModeSessionResponse = {
  booking?: ClientModeBookingReference
  session?: ClientModeSession
  token?: string
  settlement?: { status?: string; booking?: ClientModeBookingReference }
  actionToken?: string
  actionTokenExpiresAt?: number
}

export type ClientModeProgressResponse = ClientModeTravelResponse

export type ClientBookingStatus =
  | "DRAFT"
  | "QUOTED"
  | "OFFERED"
  | "ACCEPTED"
  | "RESERVED"
  | "TRAVELLING"
  | "ARRIVED"
  | "ACTIVE"
  | "COMPLETED"
  | "SETTLED"
  | "DECLINED"
  | "CANCELLED"
  | "EXPIRED"
  | "INTERRUPTED"

export type ClientBooking = {
  bookingId: string
  workerName: string
  status: ClientBookingStatus
  servicePackageId?: string
  meetingMode?: string
  locationType?: string
  amountMinor?: number
  currency?: string
  scheduledAt?: number | string
  startedAt?: number | string
  completedAt?: number | string
  etaMinutes?: number
}

export type ClientBookingPage = {
  current: ClientBooking | null
  upcoming: ClientBooking[]
  history: ClientBooking[]
  total: number
  limit: number
  offset: number
}

export type NUIRequestMap = {
  "marketplace:list": MarketplaceFilters
  "booking:quote": BookingDraft
  "booking:confirm": { quoteId: string; actionToken?: string }
  "security:action-token": { bookingId: string; action: string; generation?: string; generationToken?: string; generation_token?: string; profileKey?: string; travelKey?: string }
  "client-mode:confirm": { quoteId: string }
  "client-mode:travel": { bookingId: string; actionToken?: string }
  "client-mode:spawn": { bookingId: string; actionToken?: string }
  "client-mode:spawn-confirm": ClientModeSpawn
  "client-mode:arrival": {
    bookingId?: string
    travelKey?: string
    profileKey?: string
    generationToken?: string
    entity?: number
    networkId?: number
    position?: { x: number; y: number; z: number }
    actionToken?: string
  }
  "client-mode:session-start": { bookingId: string; locationType?: string; locationRef?: string; meetingMode?: string; actionToken?: string }
  "client-mode:session-complete": { bookingId?: string; token: string; locationType?: string; locationRef?: string; meetingMode?: string; actionToken?: string }
  "client-mode:travel-progress": { bookingId: string }
  "client-mode:recover": { bookingId: string; recoveryState: "NONE" | "STUCK" | "PLAYER_AWAY" | "ENTITY_DELETED" | "TIMEOUT" | "RETURNING"; actionToken?: string }
  "client-bookings:list": { offset?: number; limit?: number }
  "ui:close": Record<string, never>
}

export type NUIResponseMap = {
  "marketplace:list": MarketplacePage
  "booking:quote": PriceQuote
  "booking:confirm": BookingConfirmation
  "security:action-token": { token?: string; bookingId?: string; action?: string; expiresAt?: number; bypassed?: boolean }
  "client-mode:confirm": ClientModeConfirmation
  "client-mode:travel": ClientModeTravelResponse
  "client-mode:spawn": ClientModeSpawnResponse
  "client-mode:spawn-confirm": ClientModeSpawnResponse
  "client-mode:arrival": ClientModeArrivalResponse
  "client-mode:session-start": ClientModeSessionResponse
  "client-mode:session-complete": ClientModeSessionResponse
  "client-mode:travel-progress": ClientModeProgressResponse
  "client-mode:recover": ClientModeProgressResponse
  "client-bookings:list": ClientBookingPage
  "ui:close": { closed: true }
}
