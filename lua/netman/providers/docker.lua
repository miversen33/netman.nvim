local log = require("netman.utils").log
local notify = require("netman.utils").notify
local shell = require("netman.utils").run_shell_command
local shell_escape = require("netman.utils").escape_shell_command
local command_flags = require("netman.options").utils.command
local api_flags = require("netman.options").api
local string_generator = require("netman.utils").generate_string
local local_files = require("netman.utils").files_dir
local metadata_options = require("netman.options").explorer.METADATA

local invalid_permission_glob = '^Got permission denied while trying to connect to the Docker daemon socket at'

-- This will absolutely fail on busybox :(
local find_command = [[find -L $PATH$ -nowarn -depth -maxdepth 1 -printf ',{\n,name=%f\n,fullname=%p\n,lastmod_sec=%T@\n,lastmod_ts=%Tc\n,inode=%i\n,type=%Y\n,symlink=%l\n,permissions=%m\n,size=%s\n,owner_user=%u\n,owner_group=%g\n,parent=%h/\n,}\n']]
local stat_command = [[find -L $PATH$ -maxdepth 0 -exec sh -c 'for file; do stat "$file" -c \'\\'{BLKSIZE\\=%B\\,DEV\\=%d\\,GID\\=%g\\,GROUP\\=\'\\'\"%G\'\\'\"\\,INODE\\=%i\\,ATIME_SEC\\=?\\,ATIME_NSEC\\=%X\\,MTIME_SEC\\=%Y\\,MTIME_NSEC\\=?\\,CTIME_SEC\\=?\\,CTIME_NSEC\\=%Z\\,NAME\\=\'\\'\"%n\'\\'\"\\,NLINK\\=%h\\,USER\\=\'\\'\"%U\'\\'\"\\,PERMISSIONS\\=%a\\,SIZE\\=%b\\,TYPE\\=\'\\'\"%F\'\\'\"\\,UID\\=%u\\,URI\\=\'\\'\"\$URI\$\'\\'\"\\}; done' sh {} \+]]
local container_pattern     = "^([%a%c%d%s%-_%.]*)"
local path_pattern          = '^([/]+)(.*)$'
local protocol_pattern      = '^(.*)://'
local _docker_status = {
    ERROR = "ERROR",
    RUNNING = "RUNNING",
    NOT_RUNNING = "NOT_RUNNING"
}

local find_pattern_globs = {
    start_end_glob = '^,([{}])%s*'
    ,INODE = '^,inode=(.*)$'
    ,PERMISSIONS = '^,permissions=(.*)$'
    ,USER = '^,owner_user=(.*)$'
    ,GROUP = '^,owner_group=(.*)$'
    ,SIZE = '^,size=(.*)$'
    ,MOD_TIME = '^,lastmod_ts=(.*)$'
    ,FIELD_TYPE = '^,type=(.*)$'
    ,NAME = '^,name=(.*)$'
    ,PARENT = '^,parent=(.*)$'
    ,fullname = '^,fullname=(.*)$'
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


local _is_container_running = function(container)
    local command = 'docker container ls --filter "name=' .. tostring(container) .. '"'
    -- Creating command to check if the container is running
    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''
    -- Options to make our output easier to read

    log.debug("Running container life check command: " .. command)
    local command_output = shell(command, command_options)
    local stderr, stdout = command_output.stderr, command_output.stdout
    log.trace("Life Check Output ", {output=command_output})
    if stderr ~= '' then
        log.warn("Received error while checking container status: " .. stderr)
        return _docker_status.ERROR
    end
    if not stdout[2] then
        log.info("Container " .. container .. " appears to not be running")
        -- Docker container ls (or docker container ps) will always include a header line that looks like
        -- CONTAINER ID   IMAGE               COMMAND                  CREATED       STATUS      PORTS     NAMES
        -- This line is useless to us here, so we ignore the first line of output in stdout. 
        return _docker_status.NOT_RUNNING
    end
    return _docker_status.RUNNING
end

local _start_container = function(container_name)
    local command = 'docker run "' .. container_name .. '"'

    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''

    log.info("Running start container command: " .. command)
    local command_output = shell(command, command_options)
    log.debug("Container Start Output " , {output=command_output})
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
    container_file = shell_escape(container_file)
    local command = 'docker cp -L ' .. container .. ':/' .. container_file .. ' ' .. local_file

    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''

    log.info("Running container copy file command: " .. command)
    local command_output = shell(command, command_options)
    local stderr, stdout = command_output.stderr, command_output.stdout
    if stderr ~= '' then
        notify.error("Received the following error while trying to copy file from container: " .. stderr)
        return false
    end
    return true
end

local _process_find_results = function(container, results)
    local parsed_details = {}
    local partial_result = ''
    local details = {}
    local raw = ''
    local dun = false
    local size = 0
    local uri = 'docker://' .. container
    for _, result in ipairs(results) do
        dun = false
        if result:match(find_pattern_globs.start_end_glob) then
            dun = true
            goto continue
        end
        raw = raw .. result
        if result:sub(1,1) == ',' then
            partial_result = result
        else
            result = partial_result .. result
            partial_result = ''
        end
        for key, glob in pairs(find_pattern_globs) do
            local match = result:match(glob)
            if match then
                details[key] = match
                break
            end
        end
        ::continue::
        if dun and details.NAME then
            if details.FIELD_TYPE ~= 'N' then
                details.raw = raw
                details.PARENT = uri .. details.PARENT
                details.URI = uri .. details.fullname
                if details.FIELD_TYPE == 'd' then
                    details.FIELD_TYPE = metadata_options.LINK
                    details.NAME = details.NAME .. '/'
                    details.URI = details.URI .. '/'
                else
                    details.FIELD_TYPE = metadata_options.DESTINATION
                end
                table.insert(parsed_details, details)
                size = size + 1
            end
            details = {}
            dun = false
            raw = ''
        end
    end
    parsed_details[size].URI = parsed_details[size].PARENT
    parsed_details[size].NAME = '../'
    return {remote_files = parsed_details, parent = size}
end

local _read_directory = function(cache, container, directory)
    directory = shell_escape(directory)
    local command_output = {}
    local stderr, stdout = nil, nil
    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''
    if not cache.directory_command then
        log.debug("Generating Directory Traversal command")
        local commands = {
            {
                command = 'find --version'
                ,result_handler = {
                    command = find_command:gsub('%$PATH%$', directory)
                    ,result_parser = _process_find_results
                }
            },
        }
        for _, command_info in ipairs(commands) do
            log.debug("Running check command: " .. command_info.command)
            command_output = shell(command_info.command, command_options)
            stderr, stdout = command_output.stderr, command_output.stdout
            if stdout[2] == nil or stderr:match('command not found$') then
                log.info("Command: " .. command_info.command .. ' not found in container ' .. container)
            else
                cache.directory_command = command_info.result_handler.command
                cache.directory_parser = command_info.result_handler.result_parser
                goto continue
            end
        end
        log.warn("Unable to locate valid directory traversal command!")
        return nil
    end
    ::continue::
    command_output = {}
    stderr, stdout = nil, nil
    local command = 'docker exec ' .. container .. ' ' .. cache.directory_command
    log.debug("Getting directory " .. directory .. ' contents: ' .. command)
    command_output = shell(command, command_options)
    stderr, stdout = command_output.stderr, command_output.stdout
    if stderr and stderr ~= '' and not stderr:match('No such file or directory$') then
        notify.warn("Error trying to get contents of " .. directory)
        return nil
    end
    local directory_contents = cache.directory_parser(container, stdout)
    if not directory_contents then
        log.debug("Directory: " ..directory .. " returned an error of some kind in container " .. container)
        return nil
    end
    return directory_contents
end

local _write_file = function(buffer_index, uri, cache)
    vim.fn.writefile(vim.fn.getbufline(buffer_index, 1, '$'), cache.local_file)
    -- Get every line from the buffer from the first to the end and write it to the `local_file` 
    -- saved in our cache
    local local_file = shell_escape(cache.local_file)
    local container_file = shell_escape(cache.path)
    local command = 'docker cp ' .. local_file .. ' ' .. cache.container .. ':/' .. container_file
    log.debug("Saving buffer " .. buffer_index .. " to uri " .. uri .. " with command: " .. command)

    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = shell(command, command_options)
    if command_output.stderr ~= '' then
        log.warn("Received Error: " .. command_output.stderr)
        return false
    end
    return true
end

local _create_directory = function(container, directory)
    local escaped_directory = shell_escape(directory)
    local command = 'docker exec ' .. container .. ' mkdir -p ' .. escaped_directory

    log.debug("Creating directory " .. directory .. ' in container ' .. container .. ' with command: ' .. command)
    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = shell(command, command_options)
    if command_output.stderr ~= '' then
        log.warn("Received Error: " .. command_output.stderr)
        return false
    end
    return true
end

local _validate_container = function(uri, container)
    local container_status = _is_container_running(container)
    if container_status == _docker_status.ERROR then
        notify.error("Unable to find container! Check logs (:Nmlogs) for more details")
        return nil
    elseif container_status == _docker_status.NOT_RUNNING then
        log.debug("Getting input from user!")
        vim.ui.input({
            prompt = 'Container ' .. tostring(container) .. ' is not running, would you like to start it? [y/N] ',
            default = 'Y'
        }
        , function(input)
            if input:match('^[yYeEsS]$') then
                local started_container = _start_container(container)
                if started_container then require("netman"):read(uri) end
            elseif input:match('^[nNoO]$') then
                log.info("Not starting container " .. tostring(container))
                return nil
            else
                notify.info("Invalid Input. Not starting container!")
                return nil
            end
        end)
    end
    return true
end

function M:read(uri, cache)
    if next(cache) == nil then cache = _parse_uri(uri) end
    if cache.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    if not _validate_container(uri, cache.container) then return nil end
    local cwd = cache.protocol .. '://' .. cache.container
    if cache.file_type == api_flags.ATTRIBUTES.FILE then
        if _read_file(cache.container, cache.path, cache.local_file) then
            return {
                local_path = cache.local_file
                ,origin_path = uri
            }, api_flags.READ_TYPE.FILE, cwd .. cache.parent
        else
            log.warn("Failed to read remote file " .. cache.path .. '!')
            notify.info("Failed to access remote file " .. cache.path .. " on container " .. cache.container)
            return nil
        end
    else
        local directory_contents = _read_directory(cache, cache.container, cache.path)
        if not directory_contents then return nil end
        return directory_contents, api_flags.READ_TYPE.EXPLORE, cwd .. cache.path
    end
end

function M:write(buffer_index, uri, cache)
    -- It is _not_ safe to assume we already
    -- have a cache, additionally its possible
    -- that the uri provided doesn't match the
    -- cache uri so we should verify the cache
    -- we were given has contents
    if next(cache) == nil or cache.base_uri ~= uri then cache = _parse_uri(uri) end
    if cache.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    if not _validate_container(uri, cache.container) then return nil end
    local success = false
    if cache.file_type == api_flags.ATTRIBUTES.DIRECTORY then
        success = _create_directory(cache.container, cache.path)
    else
        success = _write_file(buffer_index, uri, cache)
    end
    if not success then
        notify.error("Unable to write " .. uri .. "! See logs (:Nmlogs) for more details!")
    end
end

function M:delete(uri)
    -- It is _not_ safe to assume we already
    -- have a cache, additionally its possible
    -- that the uri provided doesn't match the
    -- cache uri so we should verify the cache
    -- we were given has contents
    local cache = _parse_uri(uri)
    local path = shell_escape(cache.path)
    local command = 'docker exec ' .. cache.container .. ' rm -rf ' .. path

    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''

    vim.ui.input({
        prompt = 'Are you sure you wish to delete ' .. cache.path .. ' in container ' .. cache.container .. '? [y/N] ',
        default = 'N'
    }
    , function(input)
        if input:match('^[yYeEsS]$') then
            log.debug("Deleting URI: " .. uri .. ' with command: ' .. command)
            local command_output = shell(command, command_options)
            local success = true
            if command_output.stderr ~= '' then
                log.warn("Received Error: " .. command_output.stderr)
            end
            if success then
                notify.warn("Successfully Deleted " .. cache.path .. ' from container ' .. cache.container)
            else
                notify.warn("Failed to delete " .. cache.path .. ' from container ' .. cache.container .. '! See logs (:Nmlogs) for more details')
            end
        elseif input:match('^[nNoO]$') then
            notify.warn("Delete Request Cancelled")
        end
    end)
end

function M:init(config_options)
    local command = 'command -v docker'
    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''
    command_options[command_flags.STDOUT_JOIN] = ''

    local command_output = shell(command, command_options)
    local docker_path, error = command_output.stdout, command_output.stderr
    if error ~= '' or docker_path == '' then
        log.warn("Unable to verify docker is available to run!")
        if error ~= '' then log.warn("Found error during check for docker: " .. error) end
        if docker_path == '' then log.warn("Docker was not found on path!") end
        return false
    end

    local docker_version_command = "docker -v"
    command_output = shell(docker_version_command, command_options)
    if command_output.stdout:match(invalid_permission_glob) then
        log.warn("It appears you do not have permission to interact with docker on this machine. Please view https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user for more details")
        log.info("Received invalid docker permission error: " .. command_output.stdout)
        return false
    end
    if command_output.stderr ~= '' or command_output.stdout == '' then
        log.warn("Invalid docker version information found!")
        log.info("Received Docker Version Error: " .. command_output.stderr)
        return false
    end
    log.info("Docker path: '" .. docker_path .. "' -- Version Info: " .. command_output.stdout)
    return true
end

function M:close_connection(buffer_index, uri, cache)

end

function M.repair_uri(uri, cwd)
    log.debug("Attempting to repair: " .. uri)
    local container = ''
    _, uri = uri:match('^(.*)://(.*)$')
    log.debug("Established URI: " .. tostring(uri))
    container, uri = uri:match(container_pattern .. '(.*)')
    if not container or container:len() == 0 then
        _, container = cwd:match('^(.*)://(.*/)$')
        container, _ = container:match(container_pattern)
    end
    log.debug("Established container: " .. tostring(container) .. " and uri: " .. tostring(uri))
    if uri:sub(1,1) ~= '/' then
        uri = '/' .. uri
    end
    uri = uri:gsub('/+', '/')
    uri = M.name .. '://' .. container .. uri
    log.debug("Repair finished: " .. uri)
    return uri
end


-- THIS HURTS ALOT
function M.get_metadata(uri, requested_metadata)
    log.debug("get_metadata", {uri=uri, requested_metadata=requested_metadata})
    local metadata = {}
    uri = uri:gsub('%%', '%%%%')
    local cache = _parse_uri(uri)
    local path = shell_escape(cache.path)
    local container_name = shell_escape(cache.container)
    local _stat_command = stat_command:gsub('%$PATH%$', path)
    _stat_command = _stat_command:gsub('%$URI%$', uri)

    local command = 'docker exec ' .. container_name .. ' ' .. _stat_command
    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''
    command_options[command_flags.STDOUT_JOIN] = ''

    log.debug("Path " .. path)
    log.debug("URI " .. uri)
    log.debug("Running Find Command: " .. command)
    local command_output = shell(command, command_options)
    log.debug("Command Output", {stdout=command_output.stdout, stderr=command_output.stderr})

    if command_output.stderr:match("No such file or directory$") then
        log.info("Received error while looking for " .. uri .. ". " .. command_output.stderr)
        notify.warn(cache.path .. " does not exist in container " .. cache.container .. '!')
        return nil
    end
    if command_output.stderr ~= '' then
        log.warn("Received error while getting metadata for " .. uri .. '. ', {error=command_output.stderr})
        log.info("I can do this... Carrying on")
    end
    local unused_metadata = {}
    for _key, _ in pairs(requested_metadata) do
        unused_metadata[_key] = 1
    end

    -- THERE HAS TO BE A WAY TO IMPROVE THIS ABOMINATION
    local key, value = "", ""
    local cur_string = key
    local is_string = false
    local index = 1
    local is_escaped = false
    local key_value_match = function()
        is_escaped = false
        value = cur_string
        if value:len() > 0 and value ~= '?' and requested_metadata[key] then
            if not is_string then value = tonumber(value) end
            metadata[key] = value
            unused_metadata[key] = nil
        end
        is_string = false
        cur_string = ''
        key, value = '', ''
    end
    for char in command_output.stdout:gmatch('.') do
        if not char then break end
        if char == '\\' then
            is_escaped = true
            goto continue
        elseif char == '{' and is_escaped then
            key, value = '', ''
            cur_string = ''
            is_escaped = false
            goto continue
        elseif char == '}' and is_escaped then
            key_value_match()
            goto continue
        elseif char == ',' and is_escaped then
            -- Key AND Value pair have been matched
            key_value_match()
            goto continue
        elseif char == '=' and is_escaped then
            is_escaped = false
            key = cur_string
            cur_string = ''
            goto continue
        elseif (char == "'" or char == '"') and is_escaped then
            is_string = true
            is_escaped = false
            goto continue
        else
            is_escaped = false
            cur_string = cur_string .. char
        end
        ::continue::
        index = index + 1
    end
    local _type = metadata[metadata_options.TYPE]
    if _type ~= 'directory' then
        metadata[metadata_options.TYPE] = 'f'
    else
        metadata[metadata_options.TYPE] = 'd'
    end
    for _key, _ in pairs(unused_metadata) do
        metadata[_key] = nil
    end
    log.debug("Generated Metadata ", {metadata=metadata})
    return metadata

end

return M