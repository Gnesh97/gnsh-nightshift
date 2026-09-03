NightShift = NightShift or {}
NightShift.PhoneAdapters = NightShift.PhoneAdapters or {}
local common = NightShift.PhoneAdapters

common.lb = common._register('lb', {
    registerApp = { 'registerApp', 'lbPhoneRegister' },
    pushNotification = { 'pushNotification', 'sendNotification', 'lbPhoneNotify' },
    openApp = { 'openApp', 'openPhone', 'lbPhoneOpen' }
})
