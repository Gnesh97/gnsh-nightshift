NightShift = NightShift or {}
NightShift.PhoneAdapters = NightShift.PhoneAdapters or {}
local common = NightShift.PhoneAdapters

common.qb = common._register('qb', {
    registerApp = { 'registerApp', 'qbPhoneRegister' },
    pushNotification = { 'pushNotification', 'notify', 'sendNotification' },
    openApp = { 'openApp', 'openPhone' }
})
