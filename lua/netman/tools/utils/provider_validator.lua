local M = {}

-- The validator doesn't like the attributes nesting more than 1 deep. So don't
local _mock_provider = {
    name = {
        required = true,
        type = 'string'
    },
    init = {
        type = 'function'
    },
    protocol_patterns = {
        required = true,
        type = 'table'
    },
    version = {
        required = true,
        type = function(parent)
            local _ = type(parent)
            if _ == 'string' or _ == 'number' then
                return true
            else
                return false
            end
        end
    },
    read = {
        required = true,
        type = 'function'
    },
    read_a = {
        required = false,
        type = 'function'
    },
    write = {
        required = true,
        type = 'function'
    },
    write_a = {
        required = false,
        type = 'function'
    },
    delete = {
        required = true,
        type = 'function'
    },
    delete_a = {
        required = false,
        type = 'function'
    },
    get_metadata = {
        required = true,
        type = 'function'
    },
    get_metadata_a = {
        required = false,
        type = 'function'
    },
    copy = {
        required = false,
        type = 'function'
    },
    copy_a = {
        required = false,
        type = 'function'
    },
    move = {
        required = false,
        type = 'function'
    },
    move_a = {
        required = false,
        type = 'function'
    },
    rename = {
        required = false,
        type = 'function'
    },
    connect_host = {
        required = false,
        type = 'function'
    },
    connect_host_a = {
        required = false,
        type = 'function'
    },
    ui = {
        required = false,
        type = 'table'
    },
    ['ui.get_hosts'] = {
        required = false,
        type = 'function'
    },
    ['ui.get_host_details'] = {
        required = false,
        type = 'function'
    }
}

function M.validate(provider)
    local wrapped_provider = {}
    local missing_attrs = {}
    local failed = false
    for attr, metadata in pairs(_mock_provider) do
        local parent = provider
        local wrapped_parent = wrapped_provider
        local subattr = nil
        for _ in attr:gmatch('([^.]+)') do
            if subattr and not wrapped_parent[subattr] then
                wrapped_parent[subattr] = {}
                wrapped_parent = wrapped_parent[subattr]
            end
            subattr = _
            parent = parent[subattr]
            if not parent then
                if metadata.required then
                    failed = true
                    missing_attrs[attr] = true
                end
                goto continue
            end
        end
        local matched_type = metadata.type == type(parent)
        if type(metadata.type) == 'function' then
            matched_type = metadata.type(parent)
        end
        if not matched_type and metadata.required then
            missing_attrs[attr] = true
        end
        wrapped_parent[subattr] = parent
        ::continue::
    end
    local __ = {}
    for key, _ in pairs(missing_attrs) do table.insert(__, key) end
    missing_attrs = __
    local return_provider = {
        missing_attrs = missing_attrs,
        provider = not failed and wrapped_provider or {}
    }
    return return_provider
end

return M
