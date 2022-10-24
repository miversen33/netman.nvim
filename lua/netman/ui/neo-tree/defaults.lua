local config = {
    renderers = {
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
}

return config
