local config = {
    window = {}
}

config.renderers =
{
    file = {
        { 'indent' },
        { 'marked' },
        { 'icon' },
        { 'name' }
    },
    directory = {
        { 'indent' },
        { 'marked' },
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
    netman_refresh = {
        { 'indent' },
        { 'icon' },
        { 'name' }
    },
}

config.window.mappings = {
    -- ['f'] = "toggle_favorite",
    -- ['H'] = "toggle_hidden"
    ['d'] = 'delete_node',
    ['x'] = 'move_node',
    ['p'] = 'copy_node',
    ['m'] = 'mark_node',
}

return config
