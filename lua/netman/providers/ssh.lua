-- BUG: I dont know why but for some reason this is breaking on the work servers???
-- There is no errors being show within netman, but telescope just kinda falls over
-- when trying to figure out what the parent directory is and how to display it.
-- Consider adding even more trace logs here?????

local log = require("netman.tools.utils").log
local notify = require("netman.tools.utils").notify
local command_flags = require("netman.tools.options").utils.command
local api_flags = require("netman.tools.options").api
local string_generator = require("netman.tools.utils").generate_string
local local_files = require("netman.tools.utils").files_dir
local socket_files = require("netman.tools.utils").socket_dir
local metadata_options = require("netman.tools.options").explorer.METADATA
local shell = require("netman.tools.shell")
local CACHE = require("netman.tools.cache")

local host_pattern          = "^([%a%c%d%s%-_%.]+)"
local name_parse_pattern    = "[^/]+"
local user_pattern          = "^(.*)@"
local port_pattern          = '^:([%d]+)'
local path_pattern          = '^([/]+)(.*)$'
local protocol_pattern      = '^(.*)://'
local NO_SUCH_FILE_OR_DIRECTORY_ERROR_GLOB = 'No such file or directory$'

local SSH_CONNECTION_TIMEOUT = 10

local STAT_COMMAND = {
    'stat',
    '-L',
    '-c',
    'MODE=%f,BLOCKS=%b,BLKSIZE=%B,MTIME_SEC=%X,USER=%U,GROUP=%G,INODE=%i,PERMISSIONS=%a,SIZE=%s,TYPE=%F,NAME=%n\\\\0',
}

local PERSIST_SSH_OPTIONS = {
    '-o',
    'ControlMaster=auto',
    '-o',
    string.format('ControlPath="%s', socket_files) .. '%h-%p-%r"',
    '-o',
    string.format('ControlPersist=%s', SSH_CONNECTION_TIMEOUT)
}

-- Move this down to init so we can _live_ generate it once?
local SSH_COMMAND = {
    'ssh',
    '-o',
    'ControlMaster=auto',
    '-o',
    string.format('ControlPath="%s', socket_files) .. '%h-%p-%r"',
    '-o',
    string.format('ControlPersist=%s', SSH_CONNECTION_TIMEOUT),
}
local HOST_MATCH_GLOB = "^[%s]*Host[%s=](.*)"

local METADATA_TIMEOUT = 5 * require("netman.tools.cache").SECOND

local find_pattern_globs = {
    '^(MODE)=([%d%a]+),',
    '^(BLOCKS)=([%d]+),',
    '^(BLKSIZE)=([%d]+),',
    '^(MTIME_SEC)=([%d]+),',
    '^(USER)=([%w]+),',
    '^(GROUP)=([%w]+),',
    '^(INODE)=([%d]+),',
    '^(PERMISSIONS)=([%d]+),',
    '^(SIZE)=([%d]+),',
    '^(TYPE)=([%l%s]+),',
    '^(NAME)=(.*)$'
}
local M = {}

M.protocol_patterns = {'ssh', 'scp', 'sftp'}
M.name = 'ssh'
M.version = 0.1
M.internal = {}
M.icon = ""

function M.internal.prepare_config(config)
    if not config:get('hosts') then
        config:set('hosts', {})
        config:save()
    end
end

function M.internal.parse_user_sshconfig(config)
    local config_location = string.format("%s/.ssh/config", vim.loop.os_homedir())
    local _config = io.open(config_location, 'r')
    if not _config then
        log.warn(string.format("Unable to open user ssh config: %s", config_location))
        return
    end

    local hosts = config:get('hosts')
    for line in _config:lines() do
        local host = line:match(HOST_MATCH_GLOB)
        if host and not hosts[host] then
            hosts[host] = {}
        end
    end
    config:save()
end

--- _parse_uri will take a string uri and return an object containing details about
--- the uri provided.
--- @param uri string
---     A string representation of the uri needing parsed
--- @return table
---     This will either be an empty table (in the event of an error) or a table containing the following keys
---        base_uri
---        ,command
---        ,protocol
---        ,container
---        ,path
---        ,type
---        ,return_type
---        ,parent
function M.internal._parse_uri(uri)
    local details = {
        base_uri     = uri
        ,command     = nil
        ,protocol    = nil
        ,container   = nil
        ,path        = nil
        ,file_type   = nil
        ,return_type = nil
        ,parent      = nil
        ,local_file  = nil
    }
    log.info("Parsing URI: " .. tostring(uri))
    log.trace("Searching for protocol")
    details.protocol = uri:match(protocol_pattern)
    local valid_protocol = false
    log.trace(string.format("Validating protocol: %s", details.protocol))
    for _, protocol in ipairs(M.protocol_patterns) do
        if details.protocol == protocol then
            valid_protocol = true
            break
        end
    end
    if not valid_protocol then details.protocol = nil end
    if not details.protocol then
        log.warn("Unable to find matching protocol for " .. tostring(uri))
        return nil
    end
    log.trace("Found matching protocol: " .. details.protocol)
    uri = uri:gsub(protocol_pattern, '')
    log.trace("Searching for user")
    details.user = uri:match(user_pattern)
    if details.user then
        uri = uri:gsub(user_pattern, '')
        log.trace("Found matching user: " .. details.user)
    end
    log.trace("Searching for hostname")
    details.host = uri:match(host_pattern)
    if not details.host then
        log.warn("No hostname found for " .. uri)
        return nil
    end
    log.trace("Found matching host: " .. details.host)
    uri = uri:gsub(host_pattern, '')
    log.trace("Searching for port")
    details.port = uri:match(port_pattern)
    if details.port then
        uri = uri:gsub(port_pattern, '')
        log.trace("Found matching port: " .. details.port)
    end
    local path_head, path_body = uri:match(path_pattern)
    path_head = path_head or "/"
    path_body = path_body or ""
    if(path_head:len() == 3) then
        details.is_relative = false
    elseif (path_head:len() == 1) then
        details.is_relative = true
    else
        notify.error("Error parsing path: Unable to parse path from uri: " .. details.base_uri .. '. Path should begin with / but path begins with ' .. path_head)
        return nil
    end
    details.path = "/" .. path_body
    if details.path:sub(-1) == '/' then
        details.file_type = api_flags.ATTRIBUTES.DIRECTORY
        details.return_type = api_flags.READ_TYPE.EXPLORE
    else
        details.file_type = api_flags.ATTRIBUTES.FILE
        details.return_type = api_flags.READ_TYPE.FILE
        details.unique_name = string_generator(11)
        details.local_file  = local_files .. details.unique_name
    end
    local parent = ''
    local previous_parent = ''
    local cur_path = ''
    -- This is literal 💩 but I dont know a better way of handling this since path globs are awful...
    -- TODO: Mike: Should be able to do this better with glob gmatching
    for i=1, #details.path do
        local char = details.path:sub(i,i)
        cur_path = cur_path .. char
        if char == '/' then
            previous_parent = parent
            parent = parent .. cur_path
            cur_path = ''
        end
    end
    if cur_path == '' then parent = previous_parent end
    details.parent = parent
    details.auth_uri = details.host
    if details.user
        and not details.user:match('^([%s]*)$')
        and details.user:len() > 1 then
            details.auth_uri = details.user .. "@" .. details.host
    end
    log.trace({details=details})
    return details
end

function M.internal._process_find_result(preprocessed_result)
    local result = {raw=preprocessed_result}
    for _, pattern in ipairs(find_pattern_globs) do
        local key, value = preprocessed_result:match(pattern)
        result[key] = value
        preprocessed_result = preprocessed_result:gsub(pattern, '')
    end
    local result_name = nil
    -- Little bit of absolute file name jank to strip down to relative file name
    for name in result.NAME:gmatch(name_parse_pattern) do result_name = name end
    if not result_name then result_name = '/' end
    result.ABSOLUTE_PATH = result.NAME
    result.NAME = result_name
    if result.TYPE == 'regular file' or result.TYPE == 'regular empty file' then
        result.TYPE = 'file'
        result.FIELD_TYPE = metadata_options.DESTINATION
    else
        result.TYPE = 'directory'
        result.FIELD_TYPE = metadata_options.LINK
    end
    return result
end

-- Ensures host cache exists, and attempts to parse the provided
-- uri. If an invalid URI is provided, nil, nil is returned
-- @param provider_cache Cache
--      The cache that netman.api provided us
-- @param uri string
--      The uri to validate
-- @return cache, string or nil, nil
function M.internal._validate_cache(provider_cache, uri)
    local cached_details = provider_cache:get_item(uri)
    if cached_details then return cached_details.cache, cached_details.details end

    local uri_details = M.internal._parse_uri(uri)
    if not uri_details then
        log.warn("Unable to parse URI details!")
        return nil, nil
    end
    local cache = CACHE:new()
    if not cache:get_item('files') then
        cache:add_item('files', CACHE:new(CACHE.FOREVER), CACHE.FOREVER)
    end
    if not cache:get_item('file_metadata') then
        cache:add_item('file_metadata', CACHE:new(METADATA_TIMEOUT), CACHE.FOREVER)
    end
    provider_cache:add_item(uri, {cache=cache, details=uri_details}, CACHE.FOREVER)
    return cache, uri_details
end

function M.internal._read_file(uri_details)
    local command = {}
    if uri_details.protocol == 'sftp' or uri_details.protocol == 'scp' then
        command = {uri_details.protocol}
        if uri_details.port then
            table.insert(command, '-P')
            table.insert(command, uri_details.port)
        end
        local _auth_uri = uri_details.auth_uri .. ':'
        if uri_details.is_relative then
            _auth_uri = _auth_uri .. '.' .. uri_details.path
        else
            _auth_uri = _auth_uri .. uri_details.path
        end
        table.insert(command, _auth_uri)
        table.insert(command, uri_details.local_file)
    elseif uri_details.protocol == 'ssh' then
        log.warn("SSH as a protocol is not yet supported!")
        return nil
    else
        log.warn(string.format("Unable to process %s protocol", uri_details.protocol))
        return nil
    end
    log.info("Generated read command " .. table.concat(command, ' '))
    local command_options = {
        [command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true,
        [command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true,
        [command_flags.STDOUT_JOIN] = '',
        [command_flags.STDERR_JOIN] = '',
    }
    local command_output = shell:new(command, command_options):run()
    -- TODO: Mike: Handle missing file error, we should not _die_
    -- if a file is missing, instead prompt for if the user wants us
    -- to create it for them
    if command_output.exit_code ~= 0 then
        if command_output.stderr:match(NO_SUCH_FILE_OR_DIRECTORY_ERROR_GLOB) then
            vim.ui.input({
                prompt = string.format("%s doesn't currently exist. Create? [Y/n] ", uri_details.local_file),
                default = 'Y'
            })
        end
        log.warn("Received error while trying to fetch file " .. uri_details.base_uri, {command_output.stderr, command_output.exit_code})
        return nil, nil
    end
    local return_info = {
        local_path = uri_details.local_file,
        origin_path = uri_details.base_uri,
        unique_name = uri_details.unique_name
    }
    local remote_parent = uri_details.protocol .. '://' .. uri_details.auth_uri
    remote_parent = remote_parent .. uri_details.parent
    local parent_info = {
        local_parent = uri_details.parent,
        remote_parent = remote_parent
    }
    return return_info, parent_info
end

function M.internal._read_directory(uri_details, cache)
    local results =  cache:get_item('files'):get_item(uri_details.base_uri)
    if results and results:len() > 0 then
        return {remote_files = results:as_table(), parent = 1}
    end
    cache
        :get_item('files')
        :add_item(
            uri_details.host,
            CACHE:new(CACHE.SECOND * 5),
            CACHE.FOREVER
        )
    local children = cache:get_item('files'):get_item(uri_details.host)
    local command = {}
    for _, item in ipairs(SSH_COMMAND) do
        table.insert(command, item)
    end
    table.insert(command, uri_details.auth_uri)
    local path = uri_details.path
    if uri_details.is_relative then
        path = "~" .. path
    end
    local _find_command =
        "find -L "
        .. path
        .. ' -maxdepth 1 -mindepth 1 -exec '
        .. table.concat(STAT_COMMAND, ' ')
        .. ' {} +'
    table.insert(command, _find_command)
    local command_output = {}
    local stderr, stdout, exit_code = nil, nil, nil
    local command_options = {}
    local child = {}
    local size = 0
    command_options[command_flags.STDOUT_JOIN] = ''
    command_options[command_flags.STDERR_JOIN] = ''
    log.trace(string.format('Running ssh command %s', table.concat(command, ' ')))
    command_output = shell:new(command, command_options):run()
    stderr, stdout, exit_code = command_output.stderr, command_output.stdout, command_output.exit_code
    log.trace('SSH Directory Command and output', {command=command, options=command_options, output=command_output})
    
    -- if exit_code ~= 0 then
    --     notify.warn("Error trying to get contents of " .. tostring(uri_details.base_uri))
    --     return nil
    -- end
    stdout = stdout:gsub('\\0', string.char(0))
    for result in stdout:gmatch('[.%Z]+') do
        child = M.internal._process_find_result(result)
        child.URI = uri_details.base_uri .. child.NAME
        if
            child.FIELD_TYPE == metadata_options.LINK
            and child.URI:sub(-1, -1) ~= '/'
        then
            child.URI = child.URI .. '/'
            child.NAME = child.NAME .. '/'
        end
        -- if size == 0 then
        --     child.URI = uri_details.base_uri
        --     cache:get_item('file_metadata'):add_item(uri_details.base_uri, child)
        --     child.NAME = './'
        -- else
        cache:get_item('file_metadata'):add_item(child.URI, child)
        -- end
        children:add_item(child.URI, {URI=child.URI, FIELD_TYPE=child.FIELD_TYPE, NAME=child.NAME, ABSOLUTE_PATH=child.ABSOLUTE_PATH, METADATA=child})
        size = size + 1
    end
    return {remote_files = children:as_table()}
end

function M.internal._write_file(uri_details, lines)
    -- WARN: (Mike): The mode 664 here isn't actually 664 for some reason? Maybe it needs to be an octal, who knows
    local local_file = vim.loop.fs_open(uri_details.local_file, 'w', 664)
    assert(local_file, "Unable to write to " .. tostring(local_file))
    assert(vim.loop.fs_write(local_file, lines))
    assert(vim.loop.fs_close(local_file))

    local command = {}
    if uri_details.protocol == 'sftp' or uri_details.protocol == 'scp' then
        -- TODO: Mike: Since this is relatively static, we should prepare this on provider init instead of dynamically each time
        command = {'scp'} -- See https://stackoverflow.com/questions/16721891/single-line-sftp-from-terminal
        -- There is no straightforward way to do this with sftp... Probably want to verify scp exists
        -- During init
        if uri_details.port then
            table.insert(command, '-P')
            table.insert(command, uri_details.port)
        end
        table.insert(command, '-C')
        for _, option in ipairs(PERSIST_SSH_OPTIONS) do
            table.insert(command, option)
        end
        table.insert(command, uri_details.local_file)
        local _auth_uri = uri_details.auth_uri .. ':'
        if uri_details.is_relative then
            _auth_uri = _auth_uri .. '.' .. uri_details.path
        else
            _auth_uri = _auth_uri .. uri_details.path
        end
        table.insert(command, _auth_uri)
    elseif uri_details.protocol == 'ssh' then
        log.warn("SSH as a protocol is not yet supported!")
        command = {}
        return nil
    else
        log.warn("Unable to process " .. uri_details.protocol .. ' protocol')
        return nil
    end
    log.info("Generated read command " .. table.concat(command, ' '))
    local command_options = {
        [command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true,
        [command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true,
        [command_flags.STDOUT_JOIN] = '',
        [command_flags.STDERR_JOIN] = '',
    }
    local command_output = shell:new(command, command_options):run()
    if command_output.exit_code ~= 0 then
        log.warn("Received error while trying to save file " .. uri_details.base_uri, {command_output.stderr, command_output.exit_code})
        return false
    end
    return true
end

function M.internal._create_directory(uri_details, directory)
    local command = {}
    for _, item in ipairs(SSH_COMMAND) do
        table.insert(command, item)
    end
    table.insert(command, uri_details.auth_uri)
    table.insert(command, "mkdir")
    table.insert(command, "-p")
    table.insert(command, directory)
    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = shell:new(command, command_options):run()
    log.trace({command=command, stderr=command_output.stderr, stdout=command_output.stdout, exit_code=command_output.exit_code})
    if command_output.exit_code ~= 0 then
        log.warn("Received error while trying to create directory on", {command_output.stderr, command_output.exit_code})
        return false
    end
    return true
end

function M.read(uri, provider_cache)
    local cache, parsed_uri_details = M.internal._validate_cache(provider_cache, uri)
    local valid_protocol = false
    for _, protocol in ipairs(M.protocol_patterns) do
        if parsed_uri_details and parsed_uri_details.protocol == protocol then
            valid_protocol = true
            break
        end
    end
    if
        not parsed_uri_details
        or not valid_protocol
        or not cache then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    local parent_details = {
        local_parent = parsed_uri_details.parent,
        remote_parent = parsed_uri_details.protocol .. '://' .. parsed_uri_details.auth_uri .. '' .. parsed_uri_details.parent
    }
    if parsed_uri_details.file_type == api_flags.ATTRIBUTES.FILE then
        if M.internal._read_file(parsed_uri_details) then
            return {
                local_path = parsed_uri_details.local_file
                ,origin_path = uri
            }, api_flags.READ_TYPE.FILE, parent_details
        else
            log.warn(string.format("Failed to read remote file %s !", parsed_uri_details.path))
            notify.info(string.format("Failed to access remote file %s on remote host %s", parsed_uri_details.path, parsed_uri_details.host))
            return nil
        end
    else
        -- Consider sending the global cache and the uri along with the request and letting _read_directory manage adding stuff to the cache
        local directory_contents = M.internal._read_directory(parsed_uri_details, cache)
        if not directory_contents then return nil end
        return directory_contents, api_flags.READ_TYPE.EXPLORE, parent_details
    end
end

function M.write(uri, provider_cache, data)
    local cache, parsed_uri_details = M.internal._validate_cache(provider_cache, uri)
    local valid_protocol = false
    for _, protocol in ipairs(M.protocol_patterns) do
        if parsed_uri_details and parsed_uri_details.protocol == protocol then
            valid_protocol = true
            break
        end
    end
    if
        not parsed_uri_details
        or not valid_protocol
        or not cache then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    if parsed_uri_details.file_type == api_flags.ATTRIBUTES.FILE then
        M.internal._write_file(parsed_uri_details, data)
    else
        -- TODO: Mike: Get the name of the directory to create
        M.internal._create_directory(parsed_uri_details, data)
    end
end

function M.delete(uri, provider_cache)
    local cache, parsed_uri_details = M.internal._validate_cache(provider_cache, uri)
    local valid_protocol = false
    for _, protocol in ipairs(M.protocol_patterns) do
        if parsed_uri_details and parsed_uri_details.protocol == protocol then
            valid_protocol = true
            break
        end
    end
    if
        not parsed_uri_details
        or not valid_protocol
        or not cache then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    local command = "ssh " .. parsed_uri_details.auth_uri .. ' "rm -rf ' .. parsed_uri_details.remote_path .. '"'
    log.info("Delete command: " .. command)
    -- TODO:(Mike): Consider making this request verification for delete
    local command_output = shell.run_shell_command(command)
    if command_output.stderr then
        notify.error("Failed to delete " .. uri .. '! Check logs for more details')
        log.warn("Received Error: " .. {stderr=command_output.stderr})
    else
        notify.info("Deleted " .. uri  .. " successfully")
    end
end

function M.get_hosts(config)
    local hosts = {}
    for host, _ in pairs(config:get('hosts')) do
        local _host = {}
        _host.NAME = host
        _host.URI  = string.format("sftp://%s///", host)
        _host.STATE = ''
        table.insert(hosts, _host)
    end
    return hosts
end

function M.init(config, cache)
    M.internal.prepare_config(config)

    -- Read in the local user ssh config?
    M.internal.parse_user_sshconfig(config)
    log.info("Attempting to initialize ssh provider")
    local command = {'ssh', '-V'}
    local command_options = {
        [command_flags.STDERR_JOIN] = '',
        [command_flags.STDOUT_JOIN] = ''
    }
    local command_output = shell:new(command, command_options):run()
    if command_output.exit_code ~= 0 then
        log.warn("Unable to verify a valid ssh client is available!")
        log.info("Command and output", {command=command, output=command_output})
        return false
    end
    return true
end

function M.close_connection(buffer_index, uri, cache)
-- TODO:
end

function M.get_metadata(uri, provider_cache, requested_metadata, forced)
    local cache, parsed_uri_details = M.internal._validate_cache(provider_cache, uri)
    if not parsed_uri_details then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    cache = cache:get_item('file_metadata')
    local child = cache:get_item(uri)
    if child and not forced then
        local _child = {}
        local ded = false
        for _, key in ipairs(requested_metadata) do
            local value = child[key]
            if not value then
                ded = true
                break
            end
            _child[key] = value
        end
        if not ded then
            return _child
        end
    end
   local command = {}
    for _, item in ipairs(SSH_COMMAND) do
        table.insert(command, item)
    end
    table.insert(command, parsed_uri_details.auth_uri)
    for _, flag in ipairs(STAT_COMMAND) do
        table.insert(command, flag)
    end
    local path = parsed_uri_details.path
    if parsed_uri_details.is_relative then
        path = "~" .. path
    end
    table.insert(command, path)

    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = {}
    local stderr, stdout = nil, nil
    command_options[command_flags.STDOUT_JOIN] = ''
    command_options[command_flags.STDERR_JOIN] = ''
    command_output = shell:new(command, command_options):run()
    stderr, stdout = command_output.stderr, command_output.stdout
    if stderr and stderr ~= '' and not stderr:match('No such file or directory$') then
        notify.warn("Error trying to get metadata of " .. tostring(uri))
        log.warn({command=table.concat(command, ' '), stdout=stdout, stderr=stderr, exit_code=command_output.exit_code})
        return nil
    end
    stdout = stdout:gsub('\\0', string.char(0))
    for result in stdout:gmatch('[.%Z]+') do
        child = M.internal._process_find_result(result)
        child.URI = uri
        cache:add_item(uri, child)
    end
    local metadata = {}
    if child then
        for _, key in ipairs(requested_metadata) do
            metadata[key] = child[key]
        end
    end
    return metadata
end

return M
