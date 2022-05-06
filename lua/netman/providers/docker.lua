local log = require("netman.utils").log
local notify = require("netman.utils").notify
local shell = require("netman.utils").run_shell_command
local command_flags = require("netman.options").utils.command
local api_flags = require("netman.options").api
local string_generator = require("netman.utils").generate_string
local local_files = require("netman.utils").files_dir

local invalid_permission_glob = '^Got permission denied while trying to connect to the Docker daemon socket at'

local container_pattern     = "^([%a%c%d%s%-%.]*)"
local path_pattern          = '^([/]+)(.*)$'
local protocol_pattern      = '^(.*)://'

local M = {}

M.protocol_patterns = {'docker'}
M.name = 'docker'
M.version = 0.1

local _parse_uri = function(uri)
    local details = {
        base_uri     = uri
        ,command     = nil
        ,protocol    = nil
        ,container   = nil
        ,path        = nil
        ,type        = nil
        ,return_type = nil
        ,parent      = nil
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
        details.type = api_flags.ATTRIBUTES.DIRECTORY
        details.return_type = api_flags.READ_TYPE.EXPLORE
    else
        details.type = api_flags.ATTRIBUTES.FILE
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
function M:read(uri, cache)
    cache = _parse_uri(uri)
    if cache.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
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