import type {
  ApiResult,
  BookingConfirmation,
  ClientModeArrivalResponse,
  ClientModeConfirmation,
  ClientModeSessionResponse,
  ClientModeSpawn,
  ClientModeSpawnResponse,
  ClientModeTravelResponse,
  MarketplacePage,
  NUIRequestMap,
  NUIResponseMap,
  PriceQuote,
  WorkerCard,
} from "@/types/api"

declare global {
  interface Window {
    GetParentResourceName?: () => string
  }
}

const mockWorkers: WorkerCard[] = [
  {
    workerId: "npc:vin:001",
    displayName: "Mira Vale",
    initials: "MV",
    district: "Vinewood",
    priceClass: "premium",
    startingPrice: 650,
    rating: 4.9,
    ratingCount: 28,
    availability: "available",
    etaMinutes: 6,
    packages: ["premium", "standard"],
  },
  {
    workerId: "npc:ves:014",
    displayName: "Nora K.",
    initials: "NK",
    district: "Vespucci",
    priceClass: "standard",
    startingPrice: 480,
    rating: 4.7,
    ratingCount: 15,
    availability: "available",
    etaMinutes: 9,
    packages: ["standard"],
  },
  {
    workerId: "npc:del:007",
    displayName: "Sasha Reyes",
    initials: "SR",
    district: "Del Perro",
    priceClass: "standard",
    startingPrice: 520,
    rating: 4.8,
    ratingCount: 19,
    availability: "available",
    etaMinutes: 12,
    packages: ["standard", "extended"],
  },
]

const newRequestId = () => crypto.randomUUID?.() ?? `nui-${Date.now()}-${Math.random().toString(36).slice(2)}`

const ok = <T>(requestId: string, value: T): ApiResult<T> => ({ ok: true, requestId, value })

const fail = <T>(requestId: string, code: string, message: string): ApiResult<T> => ({
  ok: false,
  requestId,
  error: { code, message, requestId },
})

const isEmbedded = () => typeof window.GetParentResourceName === "function"

const mockEnabled = () => import.meta.env.DEV && import.meta.env.VITE_NIGHTSHIFT_MOCK === "true"

async function mockRequest<K extends keyof NUIRequestMap>(
  method: K,
  payload: NUIRequestMap[K],
  requestId: string,
): Promise<ApiResult<NUIResponseMap[K]>> {
  await new Promise((resolve) => window.setTimeout(resolve, 180))

  if (method === "marketplace:list") {
    const filters = payload as NUIRequestMap["marketplace:list"]
    const items = mockWorkers.filter((worker) => {
      const districtMatches = !filters.district || worker.district === filters.district
      const classMatches = !filters.priceClass || worker.priceClass === filters.priceClass
      return districtMatches && classMatches
    })
    return ok(requestId, { items, total: items.length, limit: 12, offset: 0, locations: [
      { locationId: "mock:come-to-me", label: "Vinewood buluşma noktası", locationType: "CONFIG_LOCATION", meetingModes: ["COME_TO_ME", "MEET_THERE"] },
      { locationId: "mock:pickup", label: "Vinewood yol kenarı", locationType: "SAFE_ROADSIDE", meetingModes: ["PICKUP"] },
    ] } as MarketplacePage as NUIResponseMap[K])
  }

  if (method === "booking:quote") {
    const draft = payload as NUIRequestMap["booking:quote"]
    const worker = mockWorkers.find((candidate) => candidate.workerId === draft.workerId)
    if (!worker) return fail(requestId, "WORKER_NOT_FOUND", "Seçilen worker artık uygun değil.")
    const packageAdjustment = draft.packageId === "premium" ? 170 : draft.packageId === "extended" ? 90 : 0
    const modeAdjustment = draft.meetingMode === "come_to_me" ? 60 : 0
    return ok(requestId, {
      quoteId: `mock-quote:${worker.workerId}:${Date.now()}`,
      amount: worker.startingPrice + packageAdjustment + modeAdjustment,
      currency: "$",
      expiresAt: Date.now() + 60_000,
      workerId: worker.workerId,
      actionToken: `mock-action:confirm:${Date.now()}`,
    } as PriceQuote as NUIResponseMap[K])
  }

  if (method === "booking:confirm") {
    const quote = payload as NUIRequestMap["booking:confirm"]
    if (!quote.quoteId) return fail(requestId, "QUOTE_INVALID", "Teklifi yenileyip tekrar dene.")
    return ok(requestId, { bookingId: `mock-${Date.now()}`, status: "RESERVED", actionToken: `mock-action:travel:${Date.now()}` } as BookingConfirmation as NUIResponseMap[K])
  }

  if (method === "client-mode:confirm") {
    return ok(requestId, {
      bookingId: "mock-booking:1",
      status: "RESERVED",
      booking: { bookingId: "mock-booking:1", status: "RESERVED" },
      worker: { workerKey: "npc:vin:001", profileKey: "npc-profile:vin:001", state: "RESERVED", bookingId: "mock-booking:1" },
      location: { locationType: "CONFIG_LOCATION", locationRef: "mock:come-to-me", meetingMode: "COME_TO_ME" },
      reservation: { reservationKey: "location:mock:come-to-me:mock-booking:1", status: "RESERVED" },
      deposit: { status: "HELD", amountMinor: 710, currency: "USD" },
      actionToken: `mock-action:travel:${Date.now()}`,
    } as ClientModeConfirmation as NUIResponseMap[K])
  }

  if (method === "client-mode:travel" || method === "client-mode:travel-progress" || method === "client-mode:recover") {
    const bookingId = (payload as { bookingId: string }).bookingId || "mock-booking:1"
    return ok(requestId, {
      bookingId,
      travelKey: `client-travel:${bookingId}:npc:vin:001`,
      booking: { bookingId, status: "TRAVELLING" },
      travel: { travelKey: `client-travel:${bookingId}:npc:vin:001`, bookingId, profileKey: "npc-profile:vin:001", mode: "WALK", state: "TRAVELLING", progress: 0.7, etaSeconds: 60, startedAt: Date.now() },
      actionToken: `mock-action:spawn:${Date.now()}`,
    } as ClientModeTravelResponse as NUIResponseMap[K])
  }

  if (method === "client-mode:spawn" || method === "client-mode:spawn-confirm") {
    const spawnPayload = payload as ClientModeSpawn
    const bookingId = spawnPayload.bookingId || "mock-booking:1"
    const travelKey = spawnPayload.travelKey || `client-travel:${bookingId}:npc:vin:001`
    const spawn = {
      bookingId,
      travelKey,
      profileKey: spawnPayload.profileKey || "npc-profile:vin:001",
      generation: spawnPayload.generation || 1,
      generationToken: spawnPayload.generationToken || "npc-generation:mock-1",
      model: "a_m_m_business_01",
      candidate: { kind: "coords" as const, x: 100, y: 200, z: 30 },
      entity: spawnPayload.entity || 701,
      networkId: spawnPayload.networkId || 88,
      serverOwned: true,
    }
    return ok(requestId, { bookingId, travelKey, profileKey: spawn.profileKey, generationToken: spawn.generationToken, entity: spawn.entity, networkId: spawn.networkId, spawn, actionToken: `mock-action:${method === "client-mode:spawn" ? "spawn-confirm" : "arrival"}:${Date.now()}` } as ClientModeSpawnResponse as NUIResponseMap[K])
  }

  if (method === "client-mode:arrival") {
    const arrivalPayload = payload as { bookingId?: string; travelKey?: string }
    const bookingId = arrivalPayload.bookingId || "mock-booking:1"
    const travelKey = arrivalPayload.travelKey || `client-travel:${bookingId}:npc:vin:001`
    return ok(requestId, {
      bookingId,
      travelKey,
      booking: { bookingId, status: "ARRIVED" },
      travel: { travelKey, bookingId, profileKey: "npc-profile:vin:001", mode: "WALK", state: "ARRIVED", progress: 1 },
      arrival: { travelKey, bookingId, profileKey: "npc-profile:vin:001", mode: "WALK", state: "ARRIVED", progress: 1 },
      actionToken: `mock-action:session-start:${Date.now()}`,
    } as ClientModeArrivalResponse as NUIResponseMap[K])
  }

  if (method === "client-mode:session-start") {
    const bookingId = (payload as { bookingId: string }).bookingId || "mock-booking:1"
    const mockSessionToken = "appointment:mock:1"
    return ok(requestId, { booking: { bookingId, status: "ACTIVE" }, session: { bookingId, token: mockSessionToken, state: "ACTIVE", startedAt: Date.now(), expiresAt: Date.now() + 900_000 }, token: mockSessionToken, actionToken: `mock-action:session-complete:${Date.now()}` } as ClientModeSessionResponse as NUIResponseMap[K])
  }

  if (method === "client-mode:session-complete") {
    const bookingId = (payload as { bookingId?: string }).bookingId || "mock-booking:1"
    return ok(requestId, { booking: { bookingId, status: "SETTLED" }, settlement: { status: "SETTLED", booking: { bookingId, status: "SETTLED" } } } as ClientModeSessionResponse as NUIResponseMap[K])
  }

  if (method === "client-bookings:list") {
    const bookingPayload = payload as NUIRequestMap["client-bookings:list"]
    return ok(requestId, { current: null, upcoming: [], history: [], total: 0, limit: bookingPayload.limit ?? 12, offset: bookingPayload.offset ?? 0 } as unknown as NUIResponseMap[K])
  }

  return ok(requestId, { closed: true } as NUIResponseMap[K])
}

export async function nuiRequest<K extends keyof NUIRequestMap>(
  method: K,
  payload: NUIRequestMap[K],
): Promise<ApiResult<NUIResponseMap[K]>> {
  const requestId = newRequestId()
  if (!isEmbedded()) {
    if (mockEnabled()) return mockRequest(method, payload, requestId)
    return fail(requestId, "NUI_UNAVAILABLE", "FiveM sunucu köprüsü bulunamadı. Development mock açık değil.")
  }

  try {
    const resourceName = window.GetParentResourceName?.()
    const response = await fetch(`https://${resourceName}/nightshift:request`, {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=UTF-8" },
      body: JSON.stringify({ requestId, method, payload }),
    })
    const result = (await response.json()) as ApiResult<NUIResponseMap[K]>
    return result.requestId ? result : fail(requestId, "NUI_RESPONSE_INVALID", "Sunucudan geçerli bir yanıt alınamadı.")
  } catch {
    return fail(requestId, "NUI_UNAVAILABLE", "Bağlantı kurulamadı. Biraz sonra tekrar dene.")
  }
}
