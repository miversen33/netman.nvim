local config = {
    window = {}
}

config.renderers =
{
    file = {
        { 'indent'  },
        { 'marked'  },
        { 'icon'    },
        { 'name'    }
    },
    directory = {
        { 'indent'  },
        { 'marked'  },
        { 'icon'    },
        { 'expanded'},
        { 'name'    }
    },
    netman_provider = {
        { 'indent'  },
        { 'expanded'},
        { 'icon'    },
        { 'name'    }
    },
    netman_host = {
        { 'indent'  },
        { 'expanded'},
        { 'state'   },
        { 'icon'    },
        { 'name'    }
    },
    netman_bookmark = {
        { 'indent' },
        { 'icon'   },
        { 'name'   }
    },
    netman_stop    = {
        { 'indent' },
        { 'icon'   },
        { 'name'   },
        { 'action' }
    },
}

config.window.mappings = {
    -- ['g'] = "toggle_favorite",
    ['x'] = 'move_node',
    ['p'] = 'paste_node',
    ['m'] = 'mark_node',
    ['y'] = "yank_node",
    -- ['f'] = 'search'
}

return config
