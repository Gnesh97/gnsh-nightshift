NightShift = NightShift or {}

NightShift.StandaloneConfig = NightShift.StandaloneConfig or {
    enabled = true,
    command = 'nightshift',
    route = '/marketplace',
    closeRoute = '/marketplace',
    messageName = 'nightshift:standalone:state',
    callbackName = 'nightshift:standalone:callback',
    -- Reuse the hardened NUI bridge so the standalone app needs no second
    -- server callback surface or server.cfg entry.
    useLibCallback = false,
    requestEvent = 'gnsh-nightshift:nui:request',
    responseEvent = 'gnsh-nightshift:nui:response',
    nuiCallbacks = {
        close = 'standalone:close',
        action = 'standalone:action',
    },
}
