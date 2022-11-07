local log = require("netman.tools.utils").log
local notify = require("netman.tools.utils").notify
local command_flags = require("netman.tools.options").utils.command
local api_flags = require("netman.tools.options").api
local string_generator = require("netman.tools.utils").generate_string
local local_files = require("netman.tools.utils").files_dir
local metadata_options = require("netman.tools.options").explorer.METADATA
local shell = require("netman.tools.shell")

local invalid_permission_glob = '^Got permission denied while trying to connect to the Docker daemon socket at'
local container_pattern       = "^([%a%c%d%s%-_%.]*)"
local name_parse_pattern      = "[^/]+"
local path_pattern            = '^([/]+)(.*)$'
local protocol_pattern        = '^(.*)://'
local _docker_status          = {
    ERROR = "ERROR",
    RUNNING = "RUNNING",
    NOT_RUNNING = "NOT_RUNNING",
    INVALID = "INVALID"
}
local STAT_COMMAND            = {
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
local M = {
    internal = {},
    ui = {}
}

M.protocol_patterns = { 'docker' }
M.name = 'docker'
M.version = 0.1

-- Check if devicons exists. If not, unicode boi!
M.ui.icon = "🐋"
local success, web_devicons = pcall(require, "nvim-web-devicons")
if success then
    local devicon, _ = web_devicons.get_icon('dockerfile')
    M.ui.icon = devicon or M.ui.icon
end

--- Returns the various containers that are currently available on the system
--- @param config Configuration
--- @return table
---     Returns a 1 dimensional table containing the name of each available container
---@diagnostic disable-next-line: unused-local
function M.ui.get_hosts(config)
    -- Note: Netman will provide our provider configuration to this function, but we 
    -- don't really need it for this work so we are going to ignore it
    local containers = M.internal._get_containers()
    local hosts = {}
    for _, container in ipairs(containers) do
        table.insert(hosts, container.name)
    end
    return hosts
end

--- Returns a list of details for a container.
--- @param config Configuration
--- @param container string
--- @param provider_cache Cache
--- @return table
---     Returns a 1 dimensional table with the following key value pairs in it
---     - NAME
---     - URI
---     - STATE
function M.ui.get_host_details(config, container, provider_cache)
    -- Kinda ick, we are basically going to cache the root directory of the container and
    -- hopefully that doesn't cause explosions?
    local _faux_uri = string.format("docker://%s/", container)
    local _ = M.internal._parse_uri(_faux_uri)
    M.internal._validate_cache(provider_cache, _)
    local cache = provider_cache:get_item(container)
    local states = require("netman.tools.options").ui.STATES
    local state = M.internal.get_container_state(container, cache, {force=true})
    local host_details = {
        NAME = container,
        URI = string.format("docker://%s/", container),
    }
    if state == _docker_status.ERROR then
        host_details.STATE = states.ERROR
    elseif state == _docker_status.RUNNING then
        host_details.STATE = states.AVAILABLE
    else
        host_details.STATE = states.UNKNOWN
    end
    return host_details
end

function M.internal.remove_item_from_cache(uri, cache, opts)
    opts = opts or {}
    if opts.clear_self then
        log.debug(string.format("Removing %s from cache", uri))
        if cache
            and cache:get_item('files') then
            -- Remove the file from local cache
            cache:get_item('files'):remove_item(uri)
        end
        if cache
            and cache:get_item('file_metadata') then
            -- Remove the file metedata from local cache
            cache:get_item('file_metadata'):remove_item(uri)
        end
    end
    if opts.clear_parent then
        -- Get parent details from our current parsed info
        local details = cache:get_item(uri)
        local parent = {}
        for part in details.path:gmatch("([^/]+)") do
            table.insert(parent, part)
        end
        -- popping the tail off the file list
        table.remove(parent, #parent)
        local parent_uri = string.format("docker://%s/%s/", details.container, table.concat(parent, "/"))
        if cache
            and cache:get_item('file_metadata') then
            -- Remove the parent metadata from local cache
            cache:get_item('file_metadata'):remove_item(parent_uri)
        end
        if cache
            and cache:get_item('files') then
            -- Remove the parent files from local cache
            cache:get_item('files'):remove_item(parent_uri)
        end
        log.debug(string.format("Removing (parent) %s from cache", parent_uri))
    end
end

--- _parse_uri will take a string uri and return an object containing details about
--- the uri provided.
--- @param uri string
---     A string representation of the uri needing parsed
--- @return table
---     This will either be an empty table (in the event of an error) or a table containing the following keys
---        base_uri
---        ,protocol
---        ,container
---        ,path
---        ,type
---        ,return_type
---        ,parent
function M.internal._parse_uri(uri)
    local details = {
        base_uri = uri
        , protocol = nil
        , container = nil
        , path = nil
        , file_type = nil
        , return_type = nil
        , parent = nil
        , local_file = nil
    }
    details.protocol = uri:match(protocol_pattern)
    uri = uri:gsub(protocol_pattern, '')
    details.container = uri:match(container_pattern) or ''
    uri = uri:gsub(container_pattern, '')
    local path_head, path_body = uri:match(path_pattern)
    path_head = path_head or "/"
    path_body = path_body or ""
    if (path_head:len() ~= 1) then
        notify.error("Error parsing path: Unable to parse path from uri: " ..
            details.base_uri .. '. Path should begin with / but path begins with ' .. path_head)
        return {}
    end
    details.path = "/" .. path_body
    if details.path:sub(-1) == '/' then
        details.file_type = api_flags.ATTRIBUTES.DIRECTORY
        details.return_type = api_flags.READ_TYPE.EXPLORE
    else
        details.file_type   = api_flags.ATTRIBUTES.FILE
        details.return_type = api_flags.READ_TYPE.FILE
        details.unique_name = string_generator(11)
        details.local_file  = local_files .. details.unique_name
    end
    local parent = ''
    local previous_parent = ''
    local cur_path = ''
    -- This is literal 💩 but I dont know a better way of handling this since path globs are awful...
    -- TODO: Mike: Should be able to do this better with glob gmatching
    for i = 1, #details.path do
        local char = details.path:sub(i, i)
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

function M.internal._process_find_result(preprocessed_result)
    local result = { raw = preprocessed_result }
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

function M.internal._validate_cache(cache, container_details)
    local CACHE_MANAGER = require('netman.tools.cache')
    local container     = container_details.container
    local path          = container_details.path
    if not cache:get_item(container) then
        log.warn("Invalid Cache details for " .. tostring(container) .. ' Generating new cache')
        -- Lets add a cache to the cache for the current container
        cache:add_item(container, CACHE_MANAGER:new(), CACHE_MANAGER.FOREVER)
    end
    cache = cache:get_item(container)
    if not cache:get_item(path) then
        -- Lets add a cache to the container's cache for the current path info
        cache:add_item(path, {}, CACHE_MANAGER.FOREVER)
        for key, value in pairs(container_details) do
            cache:get_item(path)[key] = value
        end
        cache:add_item(container_details.base_uri, container_details)
    end
    if not cache:get_item('files') then
        cache:add_item('files', CACHE_MANAGER:new(CACHE_MANAGER.FOREVER), CACHE_MANAGER.FOREVER)
    end
    if not cache:get_item('file_metadata') then
        log.trace("No file metadata cache found! Creating now")
        cache:add_item('file_metadata', CACHE_MANAGER:new(METADATA_TIMEOUT), CACHE_MANAGER.FOREVER)
    end
end

function M.internal._is_container_running(container)
    -- TODO: Mike: Probably worth caching the result of this for some short amount of time as its kinda expensive?
    local command = { 'docker', 'container', 'ls', '--all', '--format', 'table {{.Status}}', '--filter',
        'name=' .. tostring(container) }
    -- Creating command to check if the container is running
    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    -- -- Options to make our output easier to read
    local command_output = shell:new(command, command_options):run()
    local stderr, stdout, exit_code = command_output.stderr, command_output.stdout, command_output.exit_code
    if stderr ~= '' then
        log.warn(string.format("Received error while checking container status: %s", stderr))
    end
    if exit_code ~= 0 then
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

function M.internal._get_containers()
    -- -- This hurts, but might be the better way of doing this?
    -- local command = { 'docker', 'container', 'ls', '--all', '--format', '{{json .}}'}
    local command = { 'docker', 'container', 'ls', '--all', '--format',
        '{\"name\": {{json .Names}},\"status\": {{json .Status}}}' }
    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = shell:new(command, command_options):run()
    local stderr, stdout, exit_code = command_output.stderr, command_output.stdout, command_output.exit_code
    log.trace('Container Fetching Output', { command = command, output = command_output })
    if stderr ~= '' then
        log.warn(string.format("Received error while fetching containers: %s", stderr))
    end
    if exit_code ~= 0 then
        log.warn(string.format("Received Error Code: %s", exit_code))
        return {}
    end
    local _containers = {}
    for _, item in ipairs(stdout) do
        local parsed_output = vim.fn.json_decode(item)
        table.insert(_containers, parsed_output)
    end
    return _containers
end

function M.internal._start_container(container_name)
    local command = { 'docker', 'container', 'start', container_name }

    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''

    notify.info(string.format("Attempting to start `%s`", container_name))
    local command_output = shell:new(command, command_options):run()
    local stderr, stdout, exit_code = command_output.stderr, command_output.stdout, command_output.exit_code
    if exit_code ~= 0 then
        notify.error(string.format("Received the following error while trying to start container %s:%s", container_name,
            stderr))
        return false
    end
    if M.internal._is_container_running(container_name) == _docker_status.RUNNING then
        log.info("Successfully Started Container: " .. container_name)
        return true
    end
    notify.warn("Failed to start container: " .. container_name .. ' for reasons...?')
    return false
end

function M.internal._read_file(container, container_file, local_file)
    local command = { 'docker', 'cp', '-L', string.format("%s:/%s", container, container_file), local_file }

    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''

    local command_output = shell:new(command, command_options):run()
    local stderr, stdout, exit_code = command_output.stderr, command_output.stdout, command_output.exit_code
    if stderr ~= '' then
        notify.warn(string.format("Received the following error while trying to copy file from container: %s", stderr))
    end
    if exit_code ~= 0 then
        return false
    end
    return true
end

function M.internal._read_directory(uri, path, container, cache)
    local CACHE_MANAGER = require('netman.tools.cache')
    local results = cache:get_item('files'):get_item(uri)
    if results and results:len() > 0 then return { remote_files = results:as_table(), parent = 1 } end
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
        '-mindepth',
        '1',
        '-exec',
    }
    for _, flag in ipairs(STAT_COMMAND) do
        table.insert(command, flag)
    end
    table.insert(command, '{}')
    table.insert(command, '+')
    local command_output = {}
    local stderr, stdout, exit_code = nil, nil, nil
    local command_options = {}
    local child = {}
    local size = 0
    command_options[command_flags.STDOUT_JOIN] = ''
    command_options[command_flags.STDERR_JOIN] = ''
    command_output = shell:new(command, command_options):run()
    stderr, stdout, exit_code = command_output.stderr, command_output.stdout, command_output.exit_code
    log.trace('Docker Directory Command and output', { command = command, options = command_options,
        output = command_output })
    if stderr and stderr ~= '' and not stderr:match('No such file or directory$') then
        log.warn(string.format("Received STDERR output: %s", stderr))
    end
    if exit_code ~= 0 then
        log.warn(string.format("Error trying to get contents of %s", uri))
        return nil
    end
    stdout = stdout:gsub('\\0', string.char(0))
    for result in stdout:gmatch('[.%Z]+') do
        child = M.internal._process_find_result(result)
        child.URI = uri .. child.NAME
        if child.FIELD_TYPE == metadata_options.LINK
            and child.URI:sub(-1, -1) ~= '/'
        then
            child.URI = child.URI .. '/'
        end
        cache:get_item('file_metadata'):add_item(child.URI, child)
        children:add_item(child.URI,
            { URI = child.URI, FIELD_TYPE = child.FIELD_TYPE, NAME = child.NAME, ABSOLUTE_PATH = child.ABSOLUTE_PATH,
                METADATA = child })
        size = size + 1
    end
    return { remote_files = children:as_table() }
end

function M.internal._write_file(container_cache, cache, lines)
    -- Needs to clear the cache for its parent and itself if it exists
    lines = lines or {}
    lines = table.concat(lines, '\n')
    local local_file = io.open(cache.local_file, "w+")
    assert(local_file, string.format("Unable to write to %s", cache.local_file))
    assert(local_file:write(lines), string.format("Failed to write to %s", cache.local_file))
    assert(local_file:flush(), string.format("Failed to save %s", cache.local_file))
    assert(local_file:close(), string.format("Failed to close %s", cache.local_file))

    local command = { 'docker', 'cp', cache.local_file, string.format('%s:/%s', cache.container, cache.path) }

    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = shell:new(command, command_options):run()
    if command_output.stderr ~= '' then
        log.warn("Received Error: " .. command_output.stderr)
    end
    if command_output.exit_code ~= 0 then
        return false
    end
    return true
end

function M.internal._create_directory(container_cache, container, directory)
    -- Needs to clear the cache for its parent and itself if it exists
    local command = { 'docker', 'exec', container, 'mkdir', '-p', directory }

    log.trace(string.format("Creating directory %s in container %s", directory, container), {command = command})
    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = shell:new(command, command_options):run()
    if command_output.stderr ~= '' then
        log.warn("Received Error: " .. command_output.stderr)
    end
    if command_output.exit_code ~= 0 then
        return false
    end

    return true
end

function M.internal.get_container_state(container, cache, opts)
    assert(container, "No container provided to validate!")
    opts = opts or {}
    local container_status = nil
    if not opts.force and cache:get_item('container_status') == _docker_status.RUNNING then
        return _docker_status.RUNNING
    else
        container_status = M.internal._is_container_running(container)
        cache:add_item('container_status', container_status)
    end
    if container_status == _docker_status.ERROR then
        notify.error("Received an error while trying to interface with docker")
        return _docker_status.ERROR
    elseif container_status == _docker_status.INVALID then
        log.info("Unable to find container! Check logs (:Nmlogs) for more details")
        return _docker_status.INVALID
    elseif container_status == _docker_status.NOT_RUNNING then
        return _docker_status.NOT_RUNNING
    end
    return _docker_status.RUNNING
end

function M.read(uri, provider_cache)
    local parsed_uri_details = M.internal._parse_uri(uri)
    if parsed_uri_details.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    M.internal._validate_cache(provider_cache, parsed_uri_details)
    local container_cache = provider_cache:get_item(parsed_uri_details.container)
    local cache = container_cache:get_item(parsed_uri_details.path)
    local container_state = M.internal.get_container_state(cache.container, container_cache)
    if container_state == _docker_status.NOT_RUNNING then
        return {
            error = {
                message = string.format("%s is not running. Would you like to start it? [Y/n] ", cache.container),
                default = 'Y',
                callback = function(response)
                   if response:match('^[yY]') then
                        local started_container = M.internal._start_container(cache.container)
                        if started_container then
                            container_cache:add_item('container_status', _docker_status.RUNNING)
                            notify.info(string.format("%s successfully started!", cache.container))
                            return {retry = true}
                        end
                    else
                        log.info(string.format("Not starting container %s", cache.container))
                        return {retry = false}
                    end
                end
            }
        }
    end
    if cache.file_type == api_flags.ATTRIBUTES.FILE then
        if M.internal._read_file(cache.container, cache.path, cache.local_file) then
            return {
                local_path = cache.local_file,
                origin_path = cache.path
            }, api_flags.READ_TYPE.FILE
        else
            log.warn("Failed to read remote file " .. cache.path .. '!')
            log.info("Failed to access remote file " .. cache.path .. " on container " .. cache.container)
            return nil
        end
    else
        -- Consider sending the global cache and the uri along with the request and letting _read_directory manage adding stuff to the cache
        local directory_contents = M.internal._read_directory(
            uri, parsed_uri_details.path, parsed_uri_details.container, container_cache
        )
        if not directory_contents then return nil end
        return directory_contents, api_flags.READ_TYPE.EXPLORE
    end
end

function M.write(uri, provider_cache, data)
    local CACHE_MANAGER = require('netman.tools.cache')
    local cache = nil
    local parsed_uri_details = M.internal._parse_uri(uri)
    M.internal._validate_cache(provider_cache, parsed_uri_details)
    local container_cache = provider_cache:get_item(parsed_uri_details.container)
    if parsed_uri_details.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end

    if not container_cache then
        -- Lets add a cache to the cache for the current container
        container_cache = CACHE_MANAGER:new()
        provider_cache:add_item(parsed_uri_details.container, container_cache, CACHE_MANAGER.FOREVER)
    end

    if not container_cache:get_item(parsed_uri_details.path) then
        -- Lets add a cache to the container's cache for the current path info
        container_cache:add_item(parsed_uri_details.path, {}, CACHE_MANAGER.FOREVER)
        for key, value in pairs(parsed_uri_details) do
            container_cache:get_item(parsed_uri_details.path)[key] = value
        end
    end
    cache = container_cache:get_item(parsed_uri_details.path)
    if cache.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid Cache details for " .. uri)
        return nil
    end
    -- TODO: Mike, handle the fact that the container may be dead?
    -- WARN: This will break
    if M.internal.get_container_state(cache.container, container_cache)  ~= _docker_status.RUNNING then
        return nil
    end
    if parsed_uri_details.file_type == api_flags.ATTRIBUTES.FILE then
        M.internal._write_file(container_cache, cache, data)
    else
        M.internal._create_directory(container_cache, cache.container, parsed_uri_details.path)
    end
    M.internal.remove_item_from_cache(uri, container_cache, {clear_self=true, clear_parent=true})
end

function M.move(uri1, uri2, cache)
    local details_1 = M.internal._parse_uri(uri1)
    local details_2 = M.internal._parse_uri(uri2)
    M.internal._validate_cache(cache, details_1)
    M.internal._validate_cache(cache, details_2)
    if details_1.container ~= details_2.container then
        log.warn(string.format("%s and %s are not on the same container!", uri1, uri2))
        return false
    end
    local container_cache = cache:get_item(details_1.container)
    if details_1.protocol ~= M.protocol_patterns[1] then
        log.warn(string.format("Invalid URI: %s provided!", uri1))
        return false
    end
    if details_2.protocol ~= M.protocol_patterns[1] then
        log.warn(string.format("Invalid URI: %s provided!", uri2))
        return false
    end
    -- If we are here, it is safe to assume that both URIs are on the same container. Use
    -- mv to move 1 to 2. Make sure to create the parent path for 2 first
    local command, command_options, command_output
    command_options = {[command_flags.STDERR_JOIN] = ''}
    command = {"docker", "exec", details_1.container, "mkdir", "-p", details_2.parent}
    command_output = shell:new(command, command_options):run()
    log.trace({command=command, stdout=command_output.stdout, stderr=command_output.stderr, exit_code=command_output.exit_code})
    if command_output.exit_code ~= 0 then
        log.warn(string.format("Received non-0 exit code while making parent path of %s", uri2))
        return false
    end
    command = {"docker", "exec", details_1.container, "mv", details_1.path, details_2.path}
    command_output = shell:new(command, command_options):run()
    log.trace({comand=command, stdout=command_output.stdout, stderr=command_output.stderr, exit_code=command_output.exit_code})
    if command_output.exit_code ~= 0 then
        log.warn(string.format("Received non-0 exit code while moving %s to %s", uri1, uri2))
        return false
    end
    M.internal.remove_item_from_cache(uri1, container_cache, {clear_self=true, clear_parent=true})
    M.internal.remove_item_from_cache(uri2, container_cache, {clear_self=true, clear_parent=true})
    return true
end

function M.delete(uri, cache)
    -- Needs to clear the cache for its parent and itself if it exists
    -- It is _not_ safe to assume we already
    -- have a cache, additionally its possible
    -- that the uri provided doesn't match the
    -- cache uri so we should verify the cache
    -- we were given has contents
    local details = M.internal._parse_uri(uri)
    M.internal._validate_cache(cache, details)
    local container_cache = cache:get_item(details.container)
    local command = { 'docker', 'exec', details.container, 'rm', '-rf', details.path }

    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    ---@diagnostic disable-next-line: missing-parameter
    local command_output = shell:new(command, command_options):run()
    log.trace({command=command, stderr=command_output.stderr, stdout=command_output.stdout, exit_code=command_output.exit_code})
    M.internal.remove_item_from_cache(uri, container_cache, {clear_self=true, clear_parent=true})
    notify.warn("Successfully Deleted " .. details.path .. ' from container ' .. details.container)
end

function M.init(config_options, cache)
    log.info("Attempting to initialize docker provider")
    local command = { "docker", "-v" }
    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    command_options[command_flags.STDOUT_JOIN] = ''

    local command_output =
    require("netman.tools.shell"):new(command, command_options):run()
    if command_output.exit_code ~= 0 then
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

function M.close_connection(buffer_index, uri, cache)

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
    local parsed_uri_details = M.internal._parse_uri(uri)
    if parsed_uri_details.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    M.internal._validate_cache(provider_cache, parsed_uri_details)
    local cache = provider_cache:get_item(parsed_uri_details.container)
    -- Pretty ick here
    if M.internal.get_container_state(parsed_uri_details.container, cache) ~= _docker_status.RUNNING then
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
    local command = { 'docker', 'exec', parsed_uri_details.container }
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
        log.warn("Error trying to get metadata of " .. tostring(uri))
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
