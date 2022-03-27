-- TODO
-- [ ] Stop breaking LSP integration
-- [ ] Update dynamic protocol provider handling
-- [ ] We need a way to handle overriding protocol providers. I think the best way to handle this is to simply
--         override core and then accept all providers after that in a first-come-first-serve queue
-- [ ] Create way to shunt off unhandled protocols to netrw

local utils = require('netman.utils')
local notify = utils.notify

local _providers = {}
local _cache_options = nil
local _provider_required_attributes = {
    'name',
    'protocol_patterns',
    'version',
    'get_details',
    'get_unique_name',
    'read_file',
    'read_directory',
    'write_file',
    'create_directory',
    'delete_file',
    'delete_directory'
}

local protocol_pattern_sanitizer_glob = '[%%^]?([%w-.]+)[:/]?'

local load_provider = function(provider_path, options)
    -- TODO(Mike): This does not handle
    -- - DynamicProtocols after init (meaning that we dont update the AutoCommand to include those protocols
    -- - Overriding Protocols (meaning that you can theoretically have multiple providers handling the same protocol and no-one would be any wiser. Unknown bugs inbound!)
    local provider_string = ''
    options = options or _cache_options
    local status, provider = pcall(require, provider_path)
    if status then
        utils.log.info("Validating Provider: " .. provider_path)
        local missing_attrs = nil
        for _, required_attr in pairs(_provider_required_attributes) do
            if not provider[required_attr] then
                if missing_attrs then
                    missing_attrs = missing_attrs .. ', ' .. required_attr
                else
                    missing_attrs = required_attr
                end
            end
        end
        if missing_attrs then
            utils.log.info("Failed to initialize Provider: " .. provider_path .. " || Missing the following required attributes -> " .. missing_attrs)
            goto continue
        end
        utils.log.debug('Initializing Provider: ' .. provider.name .. ' --version: ' .. provider.version)
        if provider.init then
            provider.init(options)
        end
        for _, pattern in pairs(provider.protocol_patterns) do
            local _, _, new_pattern = pattern:find(protocol_pattern_sanitizer_glob)
            utils.log.debug("Reducing " .. pattern .. " down to " .. new_pattern)
            if _providers[new_pattern] then
                utils.log.info("Provider " .. _providers[new_pattern]._provider_path .. " is being overridden by " .. provider_path)
            end
            _providers[new_pattern] = provider
            new_pattern = new_pattern .. '://*'
            if provider_string == '' then
                provider_string = new_pattern
            else
                provider_string = provider_string .. ',' .. new_pattern
            end
        end
        provider._provider_path = provider_path
    else
        utils.notify.warn('Failed to initialize provider: ' .. provider_path .. '. This is likely due to it not being loaded into neovim correctly. Please ensure you have installed this plugin/provider')
    end
    ::continue::
    return provider_string
end

local get_providers_info = function(system_version)
    local neovim_details = vim.version()
    local headers = {
        '----------------------------------------------------',
        "Neovim Version: " .. neovim_details.major .. "." .. neovim_details.minor,
        "System: " .. vim.loop.os_uname().sysname,
        "Netman Version: " .. system_version,
        "Provider Details"
    }
    for pattern, provider in pairs(_providers) do
        table.insert(headers, "    " .. provider._provider_path .. " --pattern " .. pattern .. " --protocol " .. provider.name .. " --version " .. provider.version)
    end
    table.insert(headers, '----------------------------------------------------')
    return headers
end

local init = function(options)
    -- TODO(Mike): Probably want a way to roll the netman logs (in the event they are chungoy)
    if vim.g.netman_remotetools_setup == 1 then
        return
    end
    local providers = options.providers
    _cache_options = options
    utils.log.debug("Initializing Netman")
    local provider_string = ''
    if(providers) then
        utils.log.info("Loading Providers")
        --  BUG(Mike): This will create issue when there are multiple providers that handle the same
        --  thing but have slightly different provider patterns. EG
        --  sftp -> core ssh
        --  sftp:// -> some provider
        --  Both of these will be entered and saved (instead of some provider overriding core ssh) and thus
        --  we enter a race condition to find out who gets used first
        for _, _provider_path in pairs(providers) do
            local _provider_string = load_provider(_provider_path, options)
            if _provider_string:len() > 0 then
                if provider_string == '' then
                    provider_string = _provider_string
                else
                    provider_string = provider_string .. ',' .. _provider_string
                end
            end
        end
    end

    vim.g.netman_remotetools_setup = 1
    return provider_string
end

local get_remote_details = function(uri)
    local provider, details = nil, nil
    for pattern, _provider in pairs(_providers) do
        utils.log.debug("Comparing Pattern: " .. '^' .. pattern .. '://' .. " to uri: " .. uri) 
        if uri:match('^' .. pattern .. "://") then
            provider = _provider
            utils.log.info("Selecting Provider: " .. provider.name .. " for URI: " .. uri)
            break
        end
    end
    if provider == nil then
        utils.notify.error("Error parsing URI: {ENMRT01} -- Unable to establish provider for URI: " .. uri)
        return {}
    end
    details = provider.get_details(uri, notify)
    -- Expects a minimum of "host" and "remote_path", "auth_uri"
    if not details.host or not details.remote_path or not details.auth_uri then
        if not details.host then
            utils.notify.error("Error parsing URI: {ENMRT02} -- Unable to parse host from URI: " .. uri)
        end
        if not details.remote_path then
            utils.notify.error("Error parsing URI: {ENMRT03} -- Unable to parse path from URI: " .. uri)
        end
        if not details.auth_uri then
            utils.notify.error("Error parsing URI: {ENMRT04} -- Unable to parse authentication uri from URI: " .. uri)
        end
        return {}
    end
    if details.remote_path:sub(-1) == '/' then
        details.is_dir = true
    else
        details.is_file = true
    end
    details.provider = provider
    utils.log.debug("Setting provider: " .. provider.name .. " for " .. details.remote_path)
    details.buffer = vim.fn.bufnr('%')
    utils.log.debug("Setting buffer number: " .. details.buffer .. " for " .. details.remote_path)
    return details
end

local get_remote_files = function(remote_info, path)
    return remote_info.provider.read_directory(remote_info, path)
end

local get_remote_file = function(path, details)
    details = details or get_remote_details(path)
    if not details then
        utils.notify.error("Error Opening Path: {ENMRT05}")
        return
    end
    local unique_file_name = details.provider.get_unique_name(details)
    if unique_file_name == nil then
        unique_file_name = utils.generate_string(20)
        utils.log.info("It appears that " .. details.remote_path .. " doesn't exist. Generating dummy file and saving later")
        details.is_dummy = true
    end
    local lock_file = utils.lock_file(unique_file_name, details.buffer)
    if not lock_file then
        utils.notify.error("Failed to lock remote file: " .. details.remote_path)
        return nil
    end
    details.local_file_name = unique_file_name
    details.local_file  = utils.files_dir .. unique_file_name
    details.provider.read_file(details)
    return details.local_file
end

local save_remote_file = function(details)
    details.provider.write_file(details)
    if details.is_dummy then
        utils.log.info("Updating temporary file to be the newly pushed file")
        local unique_file_name = details.provider.get_unique_name(details)
        if unique_file_name ~= nil then
            utils.lock_file(unique_file_name, details.buffer)
            -- NOTE(Mike): This may _potentially_ be the cause for a race condition
            -- where you try to lock a file that didn't exist before and was
            -- magically created remotely (and pulled down locally) before this
            -- lock was created, thus causing out of sync issues between this buffer
            -- and whatever buffer you have the updated version of this file on
            -- Its highly unlikely this will ever happen and thus
            -- I wont address this yet. Just a thing to keep in the back of your mind
            utils.unlock_file(details.local_file_name)
            details.local_file_name = unique_file_name
            details.local_file = utils.files_dir .. unique_file_name
            details.is_dummy = nil
        end
    end
end

local delete_remote_file = function(details, remote_file)
    local remote_file_details = details.provider.get_details(remote_file)
    utils.log.info("Attempting to remove remote file: " .. remote_file)
    if details.is_dummy then
        return
    end
    if details.is_dir then
        details.provider.delete_directory(remote_file_details, remote_file_details.remote_path)
        utils.notify.warn("Removed remote directory " .. remote_file)
    else
        details.provider.delete_file(remote_file_details, remote_file)
        utils.notify.warn("Removed remote file " .. remote_file)
    end
end

local create_remote_directory = function(details, new_directory_name, permissions)
    details.provider.create_directory(details, new_directory_name, permissions)
    utils.log.info("Created remote directory " .. new_directory_name)
end

local cleanup = function(details)
    utils.unlock_file(details.local_file_name)
end

return {
    init                    = init,
    get_remote_details      = get_remote_details,
    get_remote_file         = get_remote_file,
    get_remote_files        = get_remote_files,
    save_remote_file        = save_remote_file,
    create_remote_directory = create_remote_directory,
    delete_remote_file      = delete_remote_file,
    load_provider           = load_provider,
    cleanup                 = cleanup,
    get_providers_info      = get_providers_info
}
