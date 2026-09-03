NightShift = NightShift or {}
NightShift.PhoneAdapters = NightShift.PhoneAdapters or {}
local common = NightShift.PhoneAdapters

common.generic = common._register('generic', {
    registerApp = { 'registerApp' },
    pushNotification = { 'pushNotification', 'sendNotification' },
    openApp = { 'openApp', 'openPhone' }
})
