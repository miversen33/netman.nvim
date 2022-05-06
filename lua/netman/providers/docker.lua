local log = require("netman.utils").log
local notify = require("netman.utils").notify
local shell = require("netman.utils").run_shell_command
local command_flags = require("netman.options").utils.command

local M = {}

M.protocol_patterns = {'docker'}
M.name = 'docker'
M.version = 0.1

function M:read(uri, cache)

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