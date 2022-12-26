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
    },
    netman_bookmark = {
        { 'indent' },
        { 'icon' },
        { 'name' }
    },
    netman_hidden = {},
    netman_spacer = {
        { 'name' }
    },
    netman_refresh = {
        { 'indent' },
        { 'icon' },
        { 'name' }
    },
}

config.window.mappings = {
    -- ['f'] = "toggle_favorite",
    -- ['H'] = "toggle_hidden"
    -- ['m'] = "cut_to_clipboard_visual"
    ['/'] = 'search'
}

return config
