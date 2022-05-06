local log = require("netman.utils").log
local notify = require("netman.utils").notify
local shell = require("netman.utils").run_shell_command
local command_flags = require("netman.options").utils.command
local api_flags = require("netman.options").api
local string_generator = require("netman.utils").generate_string
local local_files = require("netman.utils").files_dir

local invalid_permission_glob = '^Got permission denied while trying to connect to the Docker daemon socket at'

local container_pattern     = "^([%a%c%d%s%-_%.]*)"
local path_pattern          = '^([/]+)(.*)$'
local protocol_pattern      = '^(.*)://'
local _docker_status = {
    ERROR = "ERROR",
    RUNNING = "RUNNING",
    NOT_RUNNING = "NOT_RUNNING"
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
    path_body = path_body or ""
    if (path_head:len() ~= 1 and path_head:len() ~= 3) then
        notify.error("Error parsing path: Unable to parse path from uri: " .. details.base_uri .. '. Path should begin with either / (Relative) or /// (Absolute) but path begins with ' .. path_head)
        return {}
    end
    if path_head:len() == 1 then
        details.path = "$HOME/" .. path_body
    else
        details.path = "/" .. path_body
    end
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

    log.info("Running container life check command: " .. command)
    local command_output = shell(command, command_options)
    local stderr, stdout = command_output.stderr, command_output.stdout
    log.debug("Life Check Output ", {output=command_output})
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
    local command = 'docker cp -L ' .. container .. ':/' .. container_file .. ' ' .. local_file

    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''

    log.info("Running container copy file command: " .. command)
    local command_output = shell(command, command_options)
    log.debug("Container Copy Output " , {output=command_output})
    local stderr, stdout = command_output.stderr, command_output.stdout
    if stderr ~= '' then
        notify.error("Received the following error while trying to copy file from container: " .. stderr)
        return false
    end
    return true
end

function M:read(uri, cache)
    cache = _parse_uri(uri)
    if cache.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    local container_status = _is_container_running(cache.container)
    if container_status == _docker_status.ERROR then
        notify.error("Unable to find container! Check logs (:Nmlogs) for more details")
        return nil
    elseif container_status == _docker_status.NOT_RUNNING then
        log.debug("Getting input from user!")
        vim.ui.input({
            prompt = 'Container ' .. tostring(cache.container) .. ' is not running, would you like to start it? [y/N] ',
            default = 'Y'
        }
        , function(input)
            if input:match('^[yYeEsS]$') then
                local started_container = _start_container(cache.container)
                if started_container then require("netman"):read(uri) end
            elseif input:match('^[nNoO]$') then
                log.info("Not starting container " .. tostring(cache.container))
                return nil
            else
                notify.info("Invalid Input. Not starting container!")
                return nil
            end
        end)
    else
        if cache.file_type == api_flags.ATTRIBUTES.FILE then
            if _read_file(cache.container, cache.path, cache.local_file) then
                return {
                    local_path = cache.local_file
                    ,origin_path = cache.path
                }, api_flags.READ_TYPE.FILE
            else
                log.warn("Failed to read remote file " .. cache.path .. '!')
                notify.info("Failed to access remote file " .. cache.path .. " on container " .. cache.container)
                return nil
            end
        else

        end
        -- Container is running and we need to read the file/directory
    end
end

function M:write(buffer_index, uri, cache)

end

function M:delete(uri, cache)

end

function M:get_metadata(requested_metadata)

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
        notify.error("Unable to verify docker is available to run!")
        if error ~= '' then log.warn("Found error during check for docker: " .. error) end
        if docker_path == '' then log.warn("Docker was not found on path!") end
        return false
    end

    local docker_version_command = "docker -v"
    command_output = shell(docker_version_command, command_options)
    if command_output.stdout:match(invalid_permission_glob) then
        notify.error("It appears you do not have permission to interact with docker on this machine. Please view https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user for more details")
        log.info("Received invalid docker permission error: " .. command_output.stdout)
        return false
    end
    if command_output.stderr ~= '' or command_output.stdout == '' then
        notify.error("Invalid docker version information found!")
        log.info("Received Docker Version Error: " .. command_output.stderr)
        return false
    end
    log.info("Docker path: '" .. docker_path .. "' -- Version Info: " .. command_output.stdout)
    return true
end

function M:close_connection(buffer_index, uri, cache)

end

return M