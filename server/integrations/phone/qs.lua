NightShift = NightShift or {}
NightShift.PhoneAdapters = NightShift.PhoneAdapters or {}
local common = NightShift.PhoneAdapters

common.qs = common._register('qs', {
    registerApp = { 'registerApp', 'qsPhoneRegister' },
    pushNotification = { 'pushNotification', 'sendNotification', 'qsPhoneNotify' },
    openApp = { 'openApp', 'openPhone', 'qsPhoneOpen' }
})
