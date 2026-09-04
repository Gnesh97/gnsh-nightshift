local root = (... and ... ~= '') and (...) or '.'

local function read(path)
    local file, err = io.open(root .. '/' .. path, 'rb')
    assert(file, err)
    local contents = file:read('*a')
    file:close()
    return contents
end

local html = read('web/index.html')
local css = read('web/src/index.css')
local app = read('web/src/App.tsx')

assert(html:find('data%-nui%-visible="false"'), 'NUI document must start hidden before React mounts')
assert(
    html:find('<style>[%s%S]-background:%s*transparent%s*!important[%s%S]-</style>'),
    'NUI HTML must provide a transparent inline fallback before external CSS loads'
)
assert(css:find('html%[data%-nui%-visible="false"%] body'), 'hidden NUI document selector is missing')
assert(css:find('visibility:%s*hidden'), 'hidden NUI document must not paint the panel')
assert(css:find('background:%s*transparent'), 'NUI viewport background must remain transparent')
assert(not css:find('oklch%('), 'NUI CSS source must use browser-compatible color functions')
assert(app:find('document%.documentElement'), 'React visibility state must target the document root')
assert(app:find('documentRoot%.dataset%.nuiVisible'), 'React visibility state must synchronize the document gate')
assert(app:find('if %(event%.data%?%.type === "nightshift:visibility"%)'), 'NUI must only react to the visibility message')
assert(app:find('if %(!visible%) return null'), 'closed NUI must not render the application panel')
assert(app:find('if (!visible) return\n', 1, true), 'hidden NUI must defer server queries until the panel is visible')
assert(app:find('}, [district, level, visible])', 1, true), 'marketplace query must refresh when NUI visibility changes')
assert(app:find('}, [loadBookings, visible])', 1, true), 'booking query must refresh when NUI visibility changes')

local distHtml = read('web/dist/index.html')

local function assertNoDarkColorScheme(source, label)
    assert(
        not source:match('<meta[^>]-name%s*=%s*["\']color%-scheme["\']'),
        label .. ' must not declare a color-scheme meta tag'
    )
    assert(
        not source:match('[:;{]%s*color%-scheme%s*:%s*dark%s*[;}]'),
        label .. ' must not force color-scheme: dark'
    )
end

assertNoDarkColorScheme(html, 'NUI HTML source')
assertNoDarkColorScheme(css, 'NUI CSS source')
assertNoDarkColorScheme(distHtml, 'NUI built HTML')

local distCssHref = distHtml:match('href=["\']([^"\']+%.css)["\']')
assert(distCssHref, 'NUI built HTML must reference a CSS asset')
local distCss = read('web/dist/' .. distCssHref:gsub('^%./', ''))
assert(not distCss:find('oklch%('), 'NUI built CSS must use browser-compatible color functions')
assertNoDarkColorScheme(distCss, 'NUI built CSS')

local assetCount = 0
for asset in distHtml:gmatch('["\']([^"\']*assets/[^"\']+)["\']') do
    assetCount = assetCount + 1
    assert(asset:sub(1, 9) == './assets/', 'NUI dist assets must use ./assets/ relative URLs')
    assert(asset:sub(1, 1) ~= '/', 'NUI dist must not contain absolute asset URLs')
end
assert(assetCount >= 2, 'NUI dist must declare both CSS and JavaScript assets')

do
    local previousRegister = rawget(_G, 'RegisterCommand')
    local previousSetFocus = rawget(_G, 'SetNuiFocus')
    local previousSendMessage = rawget(_G, 'SendNUIMessage')
    local previousClientNui = NightShift.ClientNui
    local commands, focusCalls, messages = {}, {}, {}
    RegisterCommand = function(name, callback) commands[name] = callback end
    SetNuiFocus = function(focus, cursor) focusCalls[#focusCalls + 1] = { focus = focus, cursor = cursor } end
    SendNUIMessage = function(payload) messages[#messages + 1] = payload end
    local loaded, loadError = pcall(dofile, root .. '/client/nui.lua')
    local opened, openError = false, nil
    if loaded and commands.nightshift_marketplace then
        opened, openError = pcall(commands.nightshift_marketplace, 42, {})
    end
    RegisterCommand, SetNuiFocus, SendNUIMessage = previousRegister, previousSetFocus, previousSendMessage
    NightShift.ClientNui = previousClientNui
    assert(loaded, 'NUI client module should load in the command harness: ' .. tostring(loadError))
    assert(commands.nightshift_marketplace, 'NUI should register the marketplace-open command')
    assert(opened, 'marketplace-open command should invoke NUI.open: ' .. tostring(openError))
    assert(focusCalls[1] and focusCalls[1].focus == true and focusCalls[1].cursor == true, 'marketplace-open command should focus the NUI')
    assert(messages[1] and messages[1].type == 'nightshift:visibility' and messages[1].visible == true, 'marketplace-open command should show the NUI')
end

print('NUI visibility contracts passed: hidden bootstrap, transparent viewport, and message-gated panel')
