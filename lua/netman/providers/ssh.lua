local utils  = require("netman.utils")
local netman_options = require("netman.options")
local log    = utils.log
local notify = utils.notify

local user_pattern     = "^(.*)@"
local host_pattern     = "^([%a%c%d%s%-%.]*)"
local port_pattern     = '^:([%d]+)'
local path_pattern     = '^([/]+)(.*)$'
local protocol_pattern = '^(.*)://'

local directory_patterns = {
    name         = 'name="([%w/\\%._%- ~]*)",'
    ,fullname    = 'fullname="([%w/\\%._%- ~]*)",'
    ,inode       = 'inode=(%d*),'
    ,type        = 'type="([%w]*)",'
    ,symlink     = 'symlink="([%w/\\%._%- ~]*)",'
    ,permissions = 'permissions="([%d]*)",'
    ,size        = 'size=(%d*),'
    ,ownership   = 'ownership="([%w:]*)"'
}

local M = {}

M.name = "ssh"
M.version = "0.9"
M.protocol_patterns = {
    "ssh",
    "scp",
    "sftp"
}

M._cache_objects = {}

local _write_file = function(buffer_index, uri, cache)
    vim.fn.writefile(vim.fn.getbufline(buffer_index, 1, '$'), cache.local_file)
    local compression = ''
    -- if(use_compression) then
        -- compression = '-C '
    -- end
    local command = "scp " .. compression .. cache.local_file .. ' ' .. cache.auth_uri .. ':' .. cache.remote_path
    notify.info("Updating remote file: " .. cache.remote_path)
    log.debug("    Running Command: " .. command)

    local stdout_callback = function(job, output)
        for _, line in ipairs(output) do
            utils.log.info("STDOUT: " .. line)
        end
    end

    local stderr_callback = function(job, output)
        for _, line in ipairs(output) do
            utils.notify.warn("STDERR: " .. line)
        end
    end

    vim.fn.jobstart(command,
        {
            stdout_callback=stdout_callback,
            stderr_callback=stderr_callback
    })
    log.debug("Saved Remote File: " .. cache.remote_path .. " to " .. cache.local_file) 
end

local _create_directory = function(uri, cache, permissions)
    permissions = permissions or ""
    local command = "ssh " .. cache.auth_uri .. ' "mkdir ' .. cache.remote_path .. '"'
    local completed_successfully = true

    utils.notify.info("Creating remote directory " .. uri)
    utils.log.debug("    Command: " .. command)

    local stdout_callback = function(job, output)
        for _, line in ipairs(output) do
            utils.log.info("    STDOUT: " .. line)
        end
    end

    local stderr_callback = function(job, output)
        for _, line in ipairs(output) do
            utils.log.warn("    STDERR: " .. line)
        end
        completed_successfully = false
    end

    vim.fn.jobwait({vim.fn.jobstart(command,
        {
            stdout_callback=stdout_callback,
            stderr_callback=stderr_callback
        })
    })
    if not completed_successfully then
        utils.notify.error("Failed to create directory: " .. uri .. '! Check logs for more details')
    else
        utils.notify.info("Created " .. uri  .. " successfully")
    end
end

local _read_file = function(uri_details)
    -- read_file is used to fetch and save a remote file locally
    -- :param details(Table):
    --     A Table representing the remote file details as returned via @see get_remote_details

    local compression = ''
    -- if(use_compression) then
    --     compression = '-C '
    -- end
    utils.log.info("Connecting to host: " .. uri_details.host)
    local command = "scp " .. compression .. uri_details.auth_uri .. ':' .. uri_details.remote_path .. ' ' .. uri_details.local_file
    utils.log.debug("Running Command: " .. command)
    utils.log.info("Pulling down file: '" .. uri_details.remote_path .. "' and saving to '" .. uri_details.local_file .. "'")
    local _, exitcode, code = os.execute(command) -- TODO(Mike): Determine if this is "faster" than using vim.jobstart?
    code = code or ""
    if exitcode then
        utils.notify.error("Error Retrieving Remote File: {ENM03} -- Failed to pull down " .. uri_details.remote_path .. "! Received exitcode: " .. exitcode .. "\n\tAdditional Details: " .. code)
    end
    utils.log.debug("Saved Remote File: " .. uri_details.remote_path .. " to " .. uri_details.local_file)
    return {
        local_path   = uri_details.local_file
        ,origin_path = uri_details.base_uri
        ,unique_name = uri_details.unique_name
    }
end

local _read_directory = function(uri_details)
    local remote_files = {}
    local parent = nil
    local remote_command = 'ssh ' .. uri_details.auth_uri .. ' "find -L ' .. uri_details.remote_path .. [[ -nowarn -depth -maxdepth 1 -printf '{name = \"%f\", fullname=\"%p\", inode=%i, type=\"%Y\", symlink=\"%l\", permissions=\"%m\", size=%s, ownership=\"%u:%g\"}\n'"]]
    local command_options = {}
    command_options[netman_options.utils.command.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[netman_options.utils.command.STDERR_JOIN] = ''
    local command_output = utils.run_shell_command(remote_command, command_options)
    local stderr = command_output.stderr
    local stdout = command_output.stdout
    if stderr ~= '' then
        log.warn("Received Error: " .. stderr)
        return nil
    end
    local cache_line = ''
    local size = 0
    for _, line in ipairs(stdout) do
        if cache_line ~= '' then
            line = cache_line .. line
            cache_line = ''
        end
        if line:sub(-1) ~= '}' then
            cache_line = line
            goto continue
        end
        local _parsed_info = {}
        for pattern_name, pattern in pairs(directory_patterns) do
            _parsed_info[pattern_name] = line:match(pattern)
        end
        if _parsed_info.type == 'f' then
            _parsed_info.type = netman_options.api.ATTRIBUTES.FILE 
        end
        if _parsed_info.type == 'd' then
            _parsed_info.type = netman_options.api.ATTRIBUTES.DIRECTORY
            _parsed_info.fullname = _parsed_info.fullname .. '/'
        end

        _parsed_info.uri = uri_details.protocol .. '://' .. uri_details.auth_uri .. '//' .. _parsed_info.fullname
        table.insert(remote_files, _parsed_info)
        size = size + 1
        ::continue::
    end
    parent = remote_files[size]
    parent.uri = parent.uri .. '../'
    log.debug("Parent: ", parent)

    return {
        remote_files = remote_files
        ,parent = parent
    }
end

local _parse_uri = function(uri)
    local details = {
        base_uri     = uri
        ,host        = nil
        ,port        = nil
        ,remote_path = nil
        ,user        = nil
        ,auth_uri    = nil
        ,type        = nil
        ,return_type = nil
    }
    log.info("Parsing URI: " .. uri)
    details.protocol = uri:match(protocol_pattern)
    uri = uri:gsub(protocol_pattern, '')
    log.debug('Post protocol URI reduction: ' .. uri)
    details.user = uri:match(user_pattern) or ''
    uri = uri:gsub(user_pattern, '')
    log.debug("Matched user :" .. details.user)
    log.debug("Post user reduction: " .. uri)
    details.host = uri:match(host_pattern) or ''
    uri = uri:gsub(host_pattern, '')
    log.debug("Matched host: " .. details.host)
    log.debug("Post host reduction: " .. uri)
    details.port = uri:match(port_pattern) or ''
    uri = uri:gsub(port_pattern, '')
    log.debug("Matched port: " .. details.port)
    log.debug("Post port reduction: " .. uri)
    local path_head, path_body = uri:match(path_pattern)
    path_body = path_body or ""
    log.debug("Path Head: " .. path_head .. " Path Body: " .. path_body)
    if (path_head:len() ~= 1 and path_head:len() ~= 3) then
        notify.error("Error parsing remote path: Unable to parse path from uri: " .. details.base_uri .. '. Path should begin with either / (Relative) or /// (Absolute) but path begins with ' .. path_head)
        return {}
    end
    if path_head:len() == 1 then
        details.remote_path = "$HOME/" .. path_body
    else
        details.remote_path = "/" .. path_body
    end
    if details.remote_path:sub(-1) == '/' then
        details.type = netman_options.api.ATTRIBUTES.DIRECTORY
        details.return_type = netman_options.api.READ_TYPE.EXPLORE
    else
        details.type = netman_options.api.ATTRIBUTES.FILE
        details.return_type = netman_options.api.READ_TYPE.FILE
        details.unique_name = utils.generate_string(11)
        details.local_file  = utils.files_dir .. details.unique_name
    end
    log.debug("Path Match: " .. details.remote_path)
    if details.user and not details.user:match('%s') and details.user:len() > 1 then
        details.auth_uri = details.user .. "@" .. details.host
    else
        details.auth_uri = details.host
    end
    if details.port and not details.port:match('%s') and details.user:len() > 1 then
        details.auth_uri = details.auth_uri .. ' -p ' .. details.port
    end
    log.debug("Constructed Auth URI: " .. details.auth_uri)
    log.debug("Created Details Object: ", details)
    return details
end

local _validate_cache = function(uri, cache)
    cache = cache or {}
    if not cache.auth_uri then
        log.debug("Invalid cache found for " .. uri .. ". Creating cache now")
        for key, value in pairs(_parse_uri(uri)) do
            cache[key] = value
        end
    end
    return cache
end

function M:write(buffer_index, uri, cache)
    cache = _validate_cache(uri, cache)
    if cache.type == netman_options.api.ATTRIBUTES.DIRECTORY then
        return _create_directory(uri, cache)
    else
        return _write_file(buffer_index, uri, cache)
    end
end

function M:read(uri, cache)
    cache = _validate_cache(uri, cache)
    if cache.type == netman_options.api.ATTRIBUTES.DIRECTORY then
        return _read_directory(cache), cache.return_type
    else
        return _read_file(cache), cache.return_type
    end
end

function M:delete(uri, cache)
    cache = _validate_cache(uri, cache)
    local command = "ssh " .. cache.auth_uri .. ' "rm -rf ' .. cache.remote_path .. '"'
    log.debug("Delete command: " .. command)
    -- TODO:(Mike): Consider making this request verification for delete
    local completed_successfully = true
    local stdout_callback = function(job, output)
        for _, line in ipairs(output) do
            utils.log.info("    STDOUT: " .. line)
        end
    end

    local stderr_callback = function(job, output)
        for _, line in ipairs(output) do
            utils.log.warn("    STDERR: " .. line)
        end
        completed_successfully = false
    end

    vim.fn.jobwait({vim.fn.jobstart(command,
        {
            stdout_callback=stdout_callback,
            stderr_callback=stderr_callback
        })
    })
    if not completed_successfully then
        utils.notify.error("Failed to delete " .. uri .. '! Check logs for more details')
    else
        utils.notify.info("Deleted " .. uri  .. " successfully")
    end
end

function M:close_connection()

end

function M:init(configuration_options)

    return true
end

return M
