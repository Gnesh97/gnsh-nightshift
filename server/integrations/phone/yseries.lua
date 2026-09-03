NightShift = NightShift or {}
NightShift.PhoneAdapters = NightShift.PhoneAdapters or {}
local common = NightShift.PhoneAdapters

common.yseries = common._register('yseries', {
    registerApp = { 'registerApp', 'yseriesRegister' },
    pushNotification = { 'pushNotification', 'sendNotification', 'yseriesNotify' },
    openApp = { 'openApp', 'openPhone', 'yseriesOpen' }
})
