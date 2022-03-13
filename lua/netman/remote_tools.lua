local split  = vim.fn.split
local log    = vim.log

local utils = require('netman.utils')
local notify = utils.notify

local _providers = {}

local init = function(options)
    -- TODO(Mike): Add way to dynamically add providers _after_ init
    local providers = options.providers
    if vim.g.netman_remotetools_setup == 1 then
        return
    end
    notify("Initializing Netman", vim.log.levels.DEBUG, true)
    if(providers) then
        notify("Loading Providers", vim.log.levels.INFO, true)
        for _, _provider_path in pairs(providers) do
            local status, provider = pcall(require, _provider_path)
            if status then
                notify('Initializing ' .. provider.name .. ' Provider', log.levels.DEBUG, true)
                if provider.init then
                    provider.init(options)
                end
                table.insert(_providers, provider)
            else
                notify('Failed to initialize provider: ' .. _provider_path .. '. This is likely due to it not being loaded into neovim correctly. Please ensure you have installed this plugin/provider', vim.log.levels.WARN)
            end
        end
    end

    vim.g.netman_remotetools_setup = 1
end

local get_remote_details = function(uri)
    local provider, details = nil, nil
    for _, _provider in ipairs(_providers) do
        if _provider.is_valid(uri) then
            provider = _provider
            notify("Selecting Provider: " .. provider.name .. " for URI: " .. uri, log.levels.DEBUG)
            break
        end
    end
    if provider == nil then
        notify("Error parsing URI: {ENMRT01} -- Unable to establish provider for URI: " .. uri, log.levels.ERROR)
        return {}
    end
    details = provider.get_details(uri, notify)
    -- Expects a minimum of "host" and "remote_path", "auth_uri"
    if not details.host or details.path or not details.auth_uri then
        if not details.host then
            notify("Error parsing URI: {ENMRT02} -- Unable to parse host from URI: " .. uri, log.levels.ERROR)
        end
        if not details.path then
            notify("Error parsing URI: {ENMRT03} -- Unable to parse path from URI: " .. uri, log.levels.ERROR)
        end
        if not details.auth_uri then
            notify("Error parsing URI: {ENMRT04} -- Unable to parse authentication uri from URI: " .. uri, log.levels.ERROR)
        end
        return {}
    end
    if details.remote_path:sub(-1) == '/' then
        details.is_dir = true
    else
        details.is_file = true
    end
    details.protocol = provider.name
    details.provider = provider
    return details
end

local get_remote_files = function(remote_info, path)
    return remote_info.provider.read_directory(path, remote_info)
end

local get_remote_file = function(path, details)
    details = details or get_remote_details(path)
    if not details then
        notify("Error Opening Path: {ENMRT05}", log.levels.ERROR)
        return
    end
    local unique_file_name = details.provider.get_unique_name(details)
    if unique_file_name == nil then
        notify("Failed to retrieve remote file " .. details.remote_path, vim.log.levels.ERROR)
        return
    end
    local lock_file = utils.lock_file(unique_file_name, vim.fn.bufnr('%'))
    if not lock_file then
        notify("Failed to lock remote file: " .. details.remote_path, vim.log.levels.ERROR)
        return nil
    end
    details.local_file  = utils.files_dir .. unique_file_name
    details.provider.read_file(path, details)
    return details.local_file
end

local save_remote_file = function(file_details)
    file_details.provider.write_file(file_details)
end

return {
    init               = init,
    get_remote_details = get_remote_details,
    get_remote_file    = get_remote_file,
    get_remote_files   = get_remote_files,
    save_remote_file   = save_remote_file
}
