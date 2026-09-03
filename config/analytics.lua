NightShift = NightShift or {}

-- Read-heavy analytics summaries use a small TTL cache. The cache is an
-- optimization only; booking, payment, heat, and reputation state stay in
-- their authoritative services/repositories.
NightShift.AnalyticsCacheConfig = {
    enabled = true,
    maxEntries = 64,
    ttlSeconds = 30
}
