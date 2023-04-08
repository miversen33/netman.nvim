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
        { 'icon'   },
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
    -- ['g'] = "toggle_favorite",
    ['r'] = 'rename_node',
    ['d'] = 'delete_node',
    ['x'] = 'move_node',
    ['p'] = 'copy_node',
    ['m'] = 'mark_node',
    -- ['f'] = 'search'
}

return config
