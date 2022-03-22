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

local load_provider = function(provider_path, options)
    -- TODO(Mike): This does not handle
    -- - DynamicProtocols after init (meaning that we dont update the AutoCommand to include those protocols
    -- - Overriding Protocols (meaning that you can theoretically have multiple providers handling the same protocol and no-one would be any wiser. Unknown bugs inbound!)
    local provider_string = ''
    options = options or _cache_options
    local status, provider = pcall(require, provider_path)
    if status then
        notify('Initializing Provider: ' .. provider.name .. ' --version: ' .. provider.version, vim.log.levels.DEBUG, true)
        if provider.init then
            provider.init(options)
        end
        table.insert(_providers, provider)
        for _, pattern in pairs(provider.protocol_patterns) do
            if provider_string == '' then
                provider_string = pattern
            else
                provider_string = provider_string .. ',' .. pattern
            end
        end
        provider._provider_path = provider_path
    else
        notify('Failed to initialize provider: ' .. provider_path .. '. This is likely due to it not being loaded into neovim correctly. Please ensure you have installed this plugin/provider', vim.log.levels.WARN)
    end
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
    for _, provider in ipairs(_providers) do
        table.insert(headers, "    " .. provider._provider_path .. " --protocol " .. provider.name .. " --version " .. provider.version)
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
    notify("Initializing Netman", vim.log.levels.DEBUG, true)
    local provider_string = ''
    if(providers) then
        notify("Loading Providers", vim.log.levels.INFO, true)
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
    for _, _provider in ipairs(_providers) do
        if _provider.is_valid(uri) then
            provider = _provider
            notify("Selecting Provider: " .. provider.name .. " for URI: " .. uri, vim.log.levels.INFO, true)
            break
        end
    end
    if provider == nil then
        notify("Error parsing URI: {ENMRT01} -- Unable to establish provider for URI: " .. uri, vim.log.levels.ERROR)
        return {}
    end
    details = provider.get_details(uri, notify)
    -- Expects a minimum of "host" and "remote_path", "auth_uri"
    if not details.host or not details.remote_path or not details.auth_uri then
        if not details.host then
            notify("Error parsing URI: {ENMRT02} -- Unable to parse host from URI: " .. uri, vim.log.levels.ERROR)
        end
        if not details.remote_path then
            notify("Error parsing URI: {ENMRT03} -- Unable to parse path from URI: " .. uri,vim.log.levels.ERROR)
        end
        if not details.auth_uri then
            notify("Error parsing URI: {ENMRT04} -- Unable to parse authentication uri from URI: " .. uri,vim.log.levels.ERROR)
        end
        return {}
    end
    if details.remote_path:sub(-1) == '/' then
        details.is_dir = true
    else
        details.is_file = true
    end
    details.provider = provider
    notify("Setting provider: " .. provider.name .. " for " .. details.remote_path, vim.log.levels.DEBUG, true)
    details.buffer = vim.fn.bufnr('%')
    notify("Setting buffer number: " .. details.buffer .. " for " .. details.remote_path, vim.log.levels.DEBUG, true)
    return details
end

local get_remote_files = function(remote_info, path)
    return remote_info.provider.read_directory(remote_info, path)
end

local get_remote_file = function(path, details)
    details = details or get_remote_details(path)
    if not details then
        notify("Error Opening Path: {ENMRT05}",vim.log.levels.ERROR)
        return
    end
    local unique_file_name = details.provider.get_unique_name(details)
    if unique_file_name == nil then
        unique_file_name = utils.generate_string(20)
        notify("It appears that " .. details.remote_path .. " doesn't exist. Generating dummy file and saving later", vim.log.levels.INFO, true)
        details.is_dummy = true
    end
    local lock_file = utils.lock_file(unique_file_name, details.buffer)
    if not lock_file then
        notify("Failed to lock remote file: " .. details.remote_path, vim.log.levels.ERROR)
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
        notify("Updating temporary file to be the newly pushed file", vim.log.levels.INFO, true)
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

local delete_remote_file = function(details)
    if details.is_dummy then
        return
    end
    if details.is_dir then
        details.provider.delete_directory(details)
    else
        details.provider.delete_file(details)
    end
    notify("Removed remote file " .. details.remote_path, vim.log.levels.WARN)
end

local create_remote_directory = function(details)
    details.provider.create_directory(details)
    notify("Created remote directory " .. details.remote_path, vim.log.levels.INFO)
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
