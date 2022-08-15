local log = require("netman.tools.utils").log
local notify = require("netman.tools.utils").notify
local command_flags = require("netman.tools.options").utils.command
local api_flags = require("netman.tools.options").api
local string_generator = require("netman.tools.utils").generate_string
local local_files = require("netman.tools.utils").files_dir
local metadata_options = require("netman.tools.options").explorer.METADATA
local shell = require("netman.tools.shell")

local invalid_permission_glob = '^Got permission denied while trying to connect to the Docker daemon socket at'
local container_pattern     = "^([%a%c%d%s%-_%.]*)"
local name_parse_pattern    = "[^/]+"
local path_pattern          = '^([/]+)(.*)$'
local protocol_pattern      = '^(.*)://'
local _docker_status = {
    ERROR = "ERROR",
    RUNNING = "RUNNING",
    NOT_RUNNING = "NOT_RUNNING",
    INVALID = "INVALID"
}
local STAT_COMMAND = {
    'stat',
    '-L',
    '-c',
    'MODE=%f,BLOCKS=%b,BLKSIZE=%B,MTIME_SEC=%X,USER=%U,GROUP=%G,INODE=%i,PERMISSIONS=%a,SIZE=%s,TYPE=%F,NAME=%n\\0',
}

local METADATA_TIMEOUT = 5 * require("netman.tools.cache").SECOND
local CONTAINER_LIFE_CHECK = 1 * require("netman.tools.cache").MINUTE

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

M.protocol_patterns = {'docker'}
M.name = 'docker'
M.version = 0.1

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
local _parse_uri = function(uri)
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
    details.protocol = uri:match(protocol_pattern)
    uri = uri:gsub(protocol_pattern, '')
    details.container = uri:match(container_pattern) or ''
    uri = uri:gsub(container_pattern, '')
    local path_head, path_body = uri:match(path_pattern)
    path_head = path_head or "/"
    path_body = path_body or ""
    if (path_head:len() ~= 1) then
        notify.error("Error parsing path: Unable to parse path from uri: " .. details.base_uri .. '. Path should begin with / but path begins with ' .. path_head)
        return {}
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
    return details
end

local _process_find_result = function(preprocessed_result)
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

local _validate_cache  = function(cache, container_details)
    local CACHE_MANAGER = require('netman.tools.cache')
    local container     = container_details.container
    local path          = container_details.path
    if not cache:get_item(container) then
        log.warn("Invalid Cache details for " .. tostring(container) .. ' Generating new cache')
        if not cache:get_item(container) then
            -- Lets add a cache to the cache for the current container
            cache:add_item(container, CACHE_MANAGER:new(), CACHE_MANAGER.FOREVER)
        end
    end
    cache = cache:get_item(container)
    if not cache:get_item(path) then
        -- Lets add a cache to the container's cache for the current path info
        cache:add_item(path, {}, CACHE_MANAGER.FOREVER)
        for key, value in pairs(container_details) do
            cache:get_item(path)[key] = value
        end
    end
    if not cache:get_item('files') then
        cache:add_item('files', CACHE_MANAGER:new(CACHE_MANAGER.FOREVER), CACHE_MANAGER.FOREVER)
    end
    if not cache:get_item('file_metadata') then
        log.trace("No file metadata cache found! Creating now")
        cache:add_item('file_metadata', CACHE_MANAGER:new(METADATA_TIMEOUT), CACHE_MANAGER.FOREVER)
    end
end

local _is_container_running = function(container)
    -- TODO: Mike: Probably worth caching the result of this for some short amount of time as its kinda expensive?
    local command = {'docker', 'container', 'ls', '--all', '--format', 'table {{.Status}}', '--filter', 'name=' .. tostring(container)}
    -- Creating command to check if the container is running
    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    -- -- Options to make our output easier to read
    local command_output = shell:new(command, command_options):run()
    local stderr, stdout = command_output.stderr, command_output.stdout
    log.trace("Life Check Output ", {command=command, output=command_output})
    if stderr ~= '' then
        log.warn("Received error while checking container status: " .. stderr)
        return _docker_status.ERROR
    end
    if not stdout[2] then
        log.info("Container " .. tostring(container) .. " doesn't exist!")
        return _docker_status.INVALID
    end
    if stdout[2]:match('^Up') then
        return _docker_status.RUNNING
    else
        return _docker_status.NOT_RUNNING
    end
end

local _start_container = function(container_name)
    local command = {'docker', 'container', 'start', container_name}

    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''

    notify.info(string.format("Attempting to start `%s`", container_name))
    local command_output = shell:new(command, command_options):run()
    local stderr, stdout = command_output.stderr, command_output.stdout
    if stderr ~= '' then
        notify.error("Received the following error while trying to start container " .. container_name .. ": " .. stderr)
        return false
    end
    if _is_container_running(container_name) == _docker_status.RUNNING then
        log.info("Successfully Started Container: " .. container_name)
        return true
    end
    notify.warn("Failed to start container: " .. container_name .. ' for reasons...?')
    return false
end

local _read_file = function(container, container_file, local_file)
    local command = {'docker', 'cp', '-L', container .. ':/' .. container_file, local_file}

    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''

    local command_output = shell:new(command, command_options):run()
    local stderr, stdout = command_output.stderr, command_output.stdout
    if stderr ~= '' then
        notify.error("Received the following error while trying to copy file from container: " .. stderr)
        return false
    end
    return true
end

local _read_directory = function(uri, path, container, cache)
    local CACHE_MANAGER = require('netman.tools.cache')
    local results =  cache:get_item('files'):get_item(uri)
    if results and results:len() > 0 then return {remote_files = results:as_table(), parent = 1} end
    cache
        :get_item('files')
        :add_item(
            uri,
            CACHE_MANAGER:
                new(CACHE_MANAGER.SECOND * 5),
            CACHE_MANAGER.FOREVER
        )
    local children = cache:get_item('files'):get_item(uri)
    local command = {
        'docker',
        'exec',
        container,
        'find',
        '-L',
        path,
        '-maxdepth',
        '1',
        '-exec',
    }
    for _, flag in ipairs(STAT_COMMAND) do
        table.insert(command, flag)
    end
    table.insert(command, '{}')
    table.insert(command, '+')
    local command_output = {}
    local stderr, stdout = nil, nil
    local command_options = {}
    local child = {}
    local size = 0
    command_options[command_flags.STDOUT_JOIN] = ''
    command_options[command_flags.STDERR_JOIN] = ''
    command_output = require("netman.tools.shell"):new(command, command_options):run()
    stderr, stdout = command_output.stderr, command_output.stdout
    log.trace('Docker Directory Command and output', {command=command, options=command_options, output=command_output})
    if stderr and stderr ~= '' and not stderr:match('No such file or directory$') then
        notify.warn("Error trying to get contents of " .. tostring(uri))
        return nil
    end
    stdout = stdout:gsub('\\0', string.char(0))
    for result in stdout:gmatch('[.%Z]+') do
        child = _process_find_result(result)
        child.URI = uri .. child.NAME
        if size == 0 then
            child.URI = uri
            cache:get_item('file_metadata'):add_item(uri, child)
            child.NAME = './'
        else
            cache:get_item('file_metadata'):add_item(child.URI, child)
        end
        children:add_item(child.URI, {URI=child.URI, FIELD_TYPE=child.FIELD_TYPE, NAME=child.NAME, ABSOLUTE_PATH=child.ABSOLUTE_PATH, METADATA=child})
        size = size + 1
    end
    return {remote_files = children:as_table()}
end

local _write_file = function(cache, lines)
    -- WARN: (Mike): The mode 664 here isn't actually 664 for some reason? Maybe it needs to be an octal, who knows
    local local_file = vim.loop.fs_open(cache.local_file, 'w', 664)
    assert(local_file, "Unable to write to " .. tostring(local_file))
    assert(vim.loop.fs_write(local_file, lines))
    assert(vim.loop.fs_close(local_file))

    local command = {'docker', 'cp', cache.local_file, cache.container .. ':/' .. cache.path}

    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = shell:new(command, command_options):run()
    if command_output.stderr ~= '' then
        log.warn("Received Error: " .. command_output.stderr)
        return false
    end
    return true
end

local _create_directory = function(container, directory)
    local command = {'docker', 'exec', container, 'mkdir', '-p', directory}

    log.trace("Creating directory " .. directory .. ' in container ' .. container .. ' with command: ' .. command)
    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = shell:new(command, command_options):run()
    if command_output.stderr ~= '' then
        log.warn("Received Error: " .. command_output.stderr)
        return false
    end
    return true
end

local _validate_container = function(uri, container, cache)
    assert(container, "No container provided to validate!")
    local container_status = nil
    if cache:get_item('container_status') == _docker_status.RUNNING then
        return _docker_status.RUNNING
    else
        container_status = _is_container_running(container)
        cache:add_item('container_status', container_status)
    end
    if container_status == _docker_status.ERROR then
        notify.error("Received an error while trying to interface with docker")
        return nil
    elseif container_status == _docker_status.INVALID then
        log.info("Unable to find container! Check logs (:Nmlogs) for more details")
        return nil
    elseif container_status == _docker_status.NOT_RUNNING then
        vim.ui.input({
            prompt = 'Container ' .. tostring(container) .. ' is not running, would you like to start it? [y/N] ',
            default = 'Y'
        }
        , function(input)
            if input:match('^[yYeEsS]$') then
                local started_container = _start_container(container)
                if started_container then
                    cache:add_item('container_status', _docker_status.RUNNING)
                    require("netman").read(uri)
                end
            elseif input:match('^[nNoO]$') then
                log.info("Not starting container " .. tostring(container))
                return nil
            else
                notify.info("Invalid Input. Not starting container!")
                return nil
            end
        end)
        -- Probably should return false here?
        return false
    end
    return true
end

function M.read(uri, provider_cache)
    local parsed_uri_details = _parse_uri(uri)
    if parsed_uri_details.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    _validate_cache(provider_cache, parsed_uri_details)
    local cache = provider_cache:get_item(parsed_uri_details.container):get_item(parsed_uri_details.path)
    if not _validate_container(uri, cache.container, provider_cache:get_item(parsed_uri_details.container)) then return nil end
    if cache.file_type == api_flags.ATTRIBUTES.FILE then
        if _read_file(cache.container, cache.path, cache.local_file) then
            return {
                local_path = cache.local_file
                ,origin_path = uri
            }, api_flags.READ_TYPE.FILE, {
                local_parent = parsed_uri_details.parent
                ,remote_parent = 'docker://' .. parsed_uri_details.container .. parsed_uri_details.parent
            }
        else
            log.warn("Failed to read remote file " .. cache.path .. '!')
            notify.info("Failed to access remote file " .. cache.path .. " on container " .. cache.container)
            return nil
        end
    else
        -- Consider sending the global cache and the uri along with the request and letting _read_directory manage adding stuff to the cache
        local directory_contents = _read_directory(
            uri, parsed_uri_details.path, parsed_uri_details.container, provider_cache:get_item(parsed_uri_details.container)
        )
        if not directory_contents then return nil end
        return directory_contents, api_flags.READ_TYPE.EXPLORE, {
                local_parent = parsed_uri_details.parent
                ,remote_parent = 'docker://' .. parsed_uri_details.container .. parsed_uri_details.parent
            }
    end
end

function M.write(uri, provider_cache, data)
    local CACHE_MANAGER = require('netman.tools.cache')
    local cache = nil
    local parsed_uri_details = _parse_uri(uri)
    if parsed_uri_details.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end

    if not provider_cache:get_item(parsed_uri_details.container) then
        -- Lets add a cache to the cache for the current container
        provider_cache:add_item(parsed_uri_details.container, CACHE_MANAGER:new(), CACHE_MANAGER.FOREVER)
    end

    if not provider_cache:get_item(parsed_uri_details.container):get_item(parsed_uri_details.path) then
        -- Lets add a cache to the container's cache for the current path info
        provider_cache:get_item(parsed_uri_details.container):add_item(parsed_uri_details.path, {}, CACHE_MANAGER.FOREVER)
        for key, value in pairs(parsed_uri_details) do
            provider_cache:get_item(parsed_uri_details.container):get_item(parsed_uri_details.path)[key] = value
        end
    end
    cache = provider_cache:get_item(parsed_uri_details.container):get_item(parsed_uri_details.path)
    if cache.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid Cache details for " .. uri)
        return nil
    end
    if not _validate_container(uri, cache.container, provider_cache:get_item(parsed_uri_details.container)) then return nil end
    if parsed_uri_details.file_type == api_flags.ATTRIBUTES.FILE then
        _write_file(cache, data)
    else
        _create_directory()
    end
end

function M.delete(uri, cache)
    -- It is _not_ safe to assume we already
    -- have a cache, additionally its possible
    -- that the uri provided doesn't match the
    -- cache uri so we should verify the cache
    -- we were given has contents
    local details = _parse_uri(uri)
    local command = {'docker', 'exec', details.container, 'rm', '-rf', details.path}

    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''

    vim.ui.input({
        prompt = 'Are you sure you wish to delete ' .. details.path .. ' in container ' .. details.container .. '? [y/N] ',
        default = 'N'
    }
    , function(input)
        if input:match('^[yYeEsS]$') then
            log.trace("Deleting URI: " .. uri .. ' with command: ' .. table.concat(command, ' '))
            local command_output = shell:new(command, command_options):run()
            local success = true
            if command_output.stderr ~= '' then
                log.warn("Received Error: " .. command_output.stderr)
            end
            if success then
                notify.warn("Successfully Deleted " .. details.path .. ' from container ' .. details.container)
                if cache
                    and cache:get_item(details.container)
                    and cache:get_item(details.container):get_item('files'):get_item(uri) then
                    cache:get_item(details.container):get_item('files'):remove_item(uri)
                end
            else
                notify.warn("Failed to delete " .. details.path .. ' from container ' .. details.container .. '! See logs (:Nmlogs) for more details')
            end
        elseif input:match('^[nNoO]$') then
            notify.warn("Delete Request Cancelled")
        end
    end)
end

function M.init(config_options, cache)
    log.info("Attempting to initialize docker provider")
    local command = {"docker", "-v"}
    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    command_options[command_flags.STDOUT_JOIN] = ''

    local command_output =
        require("netman.tools.shell"):new(command, command_options):run()
    if command_output.stderr ~= '' then
        log.warn("Unable to verify docker is available to run!")
        log.info("Received error: " .. tostring(command_output.stderr))
        return false
    end

    if command_output.stdout:match(invalid_permission_glob) then
        log.warn("It appears you do not have permission to interact with the docker daemon on this machine. Please view https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user for more details")
        log.info("Received invalid docker permission error: " .. command_output.stdout)
        return false
    end
    return true
end

function M:close_connection(buffer_index, uri, cache)

end

--- Retrieves the metadata for the provided URI (as long as the URI is one that 
--- we can handle).
--- @param uri string
---     The URI to get metadata for
--- @param cache Cache
---     The provider cache
--- @param requested_metadata table
---     An array of metadata keys to attempt to retrieve
--- @param forced boolean
---     Default: false
---     If provided, this tells the provider to ignore the cache for this query
--- @return table
---     Returns a table of key, value pairs where each key is an entry from
---     @requested_metadata
function M.get_metadata(uri, provider_cache, requested_metadata, forced)
    local parsed_uri_details = _parse_uri(uri)
    if parsed_uri_details.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    _validate_cache(provider_cache, parsed_uri_details)
    local cache = provider_cache:get_item(parsed_uri_details.container)
    if not _validate_container(uri, parsed_uri_details.container, cache) then
        log.trace("Unable to get metadata for " .. tostring(uri))
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
    local command = {'docker', 'exec', parsed_uri_details.container}
    for _, flag in ipairs(STAT_COMMAND) do
        table.insert(command, flag)
    end
    table.insert(command, parsed_uri_details.path)

    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = {}
    local stderr, stdout = nil, nil
    command_options[command_flags.STDOUT_JOIN] = ''
    command_options[command_flags.STDERR_JOIN] = ''
    command_output = require("netman.tools.shell"):new(command, command_options):run()
    stderr, stdout = command_output.stderr, command_output.stdout
    if stderr and stderr ~= '' and not stderr:match('No such file or directory$') then
        notify.warn("Error trying to get metadata of " .. tostring(uri))
        return nil
    end
    stdout = stdout:gsub('\\0', string.char(0))
    for result in stdout:gmatch('[.%Z]+') do
        child = _process_find_result(result)
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
