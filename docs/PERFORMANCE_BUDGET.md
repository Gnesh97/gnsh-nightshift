# NPC streaming and scheduler budget

S28 keeps the logical worker pool independent from physical GTA entities. A
marketplace can expose many logical workers while only a bounded number of
nearby peds are admitted for each player and district.

The NightShift.NpcStreamingBudgetService owns short-lived server leases. A
lease is keyed by (player source, npc id), is idempotent for repeated spawn
requests, and is reclaimed after leaseSeconds. The default limits are:

- maxActive = 64 physical NPC leases for the resource;
- maxPerSource = 8 leases per player;
- maxPerDistrict = 32 leases per district;
- maxTracked = 512 tracked leases as a hard memory bound;
- leaseSeconds = 120.

The service returns typed budget errors instead of silently creating an
unbounded entity. Callers should release a lease when a physical ped is
despawned; expiry is the recovery path for disconnects or missed cleanup.

Travel and marketplace code must remain logical and server-owned. Navigation
ticks are only scheduled for active nearby entities, and no caller should
perform a global player-by-player or worker-by-worker scan. Future scheduler
work must use bounded batches and cache invalidation events rather than one
thread per booking.
