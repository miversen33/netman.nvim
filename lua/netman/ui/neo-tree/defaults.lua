local config = {
    window = {}
}

config.renderers =
{
    file = {
        { 'indent' },
        { 'icon' },
        { 'name' }
    },
    directory = {
        { 'indent' },
        { 'icon' },
        { 'name' }
    },
    netman_provider = {
        { 'icon' },
        { 'name' }
    },
    netman_host = {
        { 'indent' },
        { 'state' },
        { 'name' }
    }
}

config.window.mappings = {
    ['f'] = "toggle_favorite",
    ['H'] = "toggle_hidden"
}

return config
