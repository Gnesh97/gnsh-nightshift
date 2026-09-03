NightShift = NightShift or {}

-- Security defaults are intentionally conservative but backwards compatible:
-- rate limiting is on for network requests, while action-token enforcement is
-- opt-in until every external caller has been migrated to the token contract.
NightShift.SecurityConfig = NightShift.SecurityConfig or {
    enabled = true,
    persistentCounters = false,
    maxBuckets = 2048,
    rateLimit = {
        enabled = true,
        default = { capacity = 20, refillPerSecond = 2, cost = 1 },
        actions = {
            ['marketplace:list'] = { capacity = 30, refillPerSecond = 4, cost = 1 },
            ['booking:quote'] = { capacity = 8, refillPerSecond = 0.5, cost = 1 },
            ['booking:confirm'] = { capacity = 3, refillPerSecond = 0.1, cost = 1 },
            ['client-mode:confirm'] = { capacity = 3, refillPerSecond = 0.1, cost = 1 },
            ['client-mode:arrival'] = { capacity = 6, refillPerSecond = 0.5, cost = 1 },
            ['client-mode:session-start'] = { capacity = 3, refillPerSecond = 0.1, cost = 1 },
            ['client-mode:session-complete'] = { capacity = 3, refillPerSecond = 0.1, cost = 1 },
            ['review:submit'] = { capacity = 3, refillPerSecond = 0.05, cost = 1 },
            ['favorite:add'] = { capacity = 10, refillPerSecond = 0.5, cost = 1 },
            ['favorite:remove'] = { capacity = 10, refillPerSecond = 0.5, cost = 1 }
        }
    },
    actionTokens = {
        enabled = true,
        enforce = false,
        ttlSeconds = 90,
        maxActive = 4096,
        maxTokenLength = 192
    }
}

-- Keep the namespace separate from the user-editable config table.  Service
-- constructors attach themselves under NightShift.Security at runtime; aliasing
-- the tables would make those constructors look like unknown config fields.
if NightShift.Security == NightShift.SecurityConfig then NightShift.Security = nil end
NightShift.Security = NightShift.Security or {}
NightShift.Security.Config = NightShift.SecurityConfig
