fx_version 'cerulean'
game 'gta5'
lua54 'yes'

shared_scripts {
    'shared/enums.lua',
    'shared/errors.lua',
    'shared/constants.lua',
    'shared/schemas.lua',
    'shared/validators.lua',
    'config/providers.lua',
    'config/features.lua',
    'config/config.lua'
}

server_scripts {
    'server/core/result.lua',
    'server/core/clock.lua',
    'server/core/logger.lua',
    'server/core/event_bus.lua',
    'server/bootstrap.lua'
}
client_script 'client/bootstrap.lua'
