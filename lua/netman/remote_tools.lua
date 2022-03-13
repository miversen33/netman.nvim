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
    local provider, details = nil
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
    remote_info = remote_info or get_remote_details(path)
    local remote_files = {
        dirs  = {
            hidden = {},
            visible = {}
        },
        files = {
            hidden = {},
            visible = {},
        }, 
        links = { -- TODO(Mike): Command right now does _not_ resolve links locations. 
            hidden = {},
            visible = {} 
        }
    }
    local stdout_callback = function(job, output)
        for _, line in ipairs(output) do
            local _,_, type = line:find('^(%a)')
            line = line:gsub('^(%a)|', "")
            local _,_, is_empty = line:find('^[%s]*$')
            if not line or line:len() == 0 or is_empty then goto continue end
            local is_hidden,_ = line:find('^%.')
            local store_table = nil
            if type == 'd' then
                if is_hidden then
                    store_table = remote_files.dirs.hidden
                else
                    store_table = remote_files.dirs.visible
                end
            elseif type == 'f' then
                if is_hidden then
                    store_table = remote_files.files.hidden
                else
                    store_table = remote_files.files.visible
                end
            elseif type == 'N' then
                if is_hidden then
                    store_table = remote_files.links.hidden
                else
                    store_table = remote_files.links.visible
                end
            end
            if store_table then
                table.insert(store_table, {
                    relative_path = line,
                    full_path = remote_info.remote_path .. line
                })
            end
        ::continue::
        end
    end
    local stderr_callback = function(job, output)
        for _, line in ipairs(output) do
            if not line or line:len() == 0 then goto continue end
            notify("Error Browsing Remote Directory: {ENM04} -- STDERR: " .. line, log.levels.ERROR)
            ::continue::
        end
    end
    local command = 'ssh ' .. remote_info.auth_uri .. ' "find ' .. remote_info.remote_path .. ' -maxdepth 1 -printf \'%Y|%P\n\' | gzip -c" | gzip -d -c'

    local job = vim.fn.jobstart(
        command
        ,{
            on_stdout = stdout_callback,
            on_stderr = stderr_callback,
        })
    vim.fn.jobwait({job})

    return remote_files

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
