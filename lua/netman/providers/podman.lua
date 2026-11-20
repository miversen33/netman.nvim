local logger = require("netman.tools.utils").get_provider_logger()
local api_flags = require("netman.tools.options").api
local local_files = require("netman.tools.utils").files_dir
local ui_states = require("netman.tools.options").ui.STATES
local shell = require("netman.tools.shell")
local command_flags = shell.CONSTANTS.FLAGS
local Container = require("netman.providers.container")

local M = {
    internal = {},
    ui = {},
    archive = {}
}

-- Check if devicons exists. If not, unicode boi!
M.ui.icon = "🦭"
local success, web_devicons = pcall(require, "nvim-web-devicons")
if success then
    local devicon, _ = web_devicons.get_icon('containerfile')
    M.ui.icon = devicon or M.ui.icon
end

-- Creating the provider
M.internal.Container = Container
M.internal.URI = Container.URI
M.name = 'podman'
M.protocol_patterns = {'podman'}
M.version = 0.1

function M.init()
    -- Check if podman is installed??
    -- Check if the user can use podman
    local check_podman_command = { "podman", "-v" }
    local _ = { [command_flags.STDOUT_JOIN] = '', [command_flags.STDERR_JOIN] = '' }
    local __ = shell:new(check_podman_command, _):run()
    logger.trace(__)
    if __.exit_code ~= 0 then
        local _error = "Unable to verify podman is available to run"
        logger.warn(_error, { exit_code = __.exit_code, stderr = __.stderr })
        return false
    end
    return true
end

function M.connect_host(uri, cache)
    assert(M.init(), "podman provider not initialized")
    local validation = M.internal.validate(uri, cache)
    if validation.message then return validation end
    return {success = true}
end

function M.internal.validate(uri, cache)
    assert(cache, string.format("No cache provided for read of %s",  uri))
    ---@diagnostic disable-next-line: cast-local-type
    uri = M.internal.URI:new(uri, cache)

    local container = M.internal.Container:new("podman", uri.container, cache)
    -- Is the container running???
    if container:current_status() ~= M.internal.Container.CONSTANTS.STATUS.RUNNING then
        return {
            message = {
                message = string.format("%s is not running. Would you like to start it? [Y/n] ", container.name),
                default = 'Y',
                callback = function(response)
                   if response:match('^[yY]') then
                        local started = container:start()
                        if started.success then
                            logger.infon(string.format("%s successfully started!", container.name))
                            return true
                        else
                            -- TODO: We are not passing the error up and that _may_ be and...
                            return false
                        end
                    else
                        logger.info(string.format("Not starting container %s", container.name))
                        return false
                    end
                end
            }
        }
    end
    return {uri = uri, container = container}
end

function M.internal.find(uri, container, opts)
    opts = opts or {}
    if not opts.exec then
        opts.exec = 'stat -L -c MODE=%f,BLOCKS=%b,BLKSIZE=%B,MTIME_SEC=%X,USER=%U,GROUP=%G,INODE=%i,PERMISSIONS=%a,SIZE=%s,TYPE=%F,NAME=%n'
    end
    local raw_children = container:find(uri, opts)
    if raw_children.error and not opts.ignore_errors then
        return {success = false, message = raw_children.error}
    end

    local children = container:_stat_parse(raw_children)
    local __ = {}
    for _, metadata in pairs(children) do
        __[metadata.URI] = {
            URI = metadata.URI,
            FIELD_TYPE = metadata.FIELD_TYPE,
            NAME = metadata.NAME,
            -- Child will always be the absolute path, and its ever so slightly cheaper to do a straight memory reference as opposed
            -- to a hash lookup and memory reference
            ABSOLUTE_PATH = metadata.ABSOLUTE_PATH,
            METADATA = metadata
        }
    end
    return { success = true, data = __ }
end

function M.internal.read_directory(uri, container)
    local children = M.internal.find(uri, container, {max_depth = 1})
    if not children.success then
        -- Something happened during find.
        if children.error:match('[pP]ermission%s+[dD]enied') then
            return {
                success = false,
                message = {
                    message = string.format("Permission Denied when accessing %s", uri:to_string())
                }
            }
        end
        -- Handle other errors as we find them
        return {
            success = false,
            message = children.error
        }
    end
    return {
        success = true,
        data = children.data,
        type = api_flags.READ_TYPE.EXPLORE
    }
end

function M.internal.read_file(uri, container)
    local status = container:get(uri, local_files, {new_file_name = uri.unique_name})
    local obj = nil
    if status.success then
        obj = {
            success = true,
            data = {
                local_path = string.format("%s%s", local_files, uri.unique_name),
                origin_path = uri:to_string()
            },
            type = api_flags.READ_TYPE.FILE
        }
    end
    if status.error then
        local handled = false
        if status.error:match('[pP]ermission%s+[dD]enied') then
            handled = true
            obj = {
                success = false,
                message = {
                    message = "Permission Denied",
                    error = api_flags.ERRORS.PERMISSION_ERROR
                }
            }
        end
        if not handled then
            logger.warn("Received unhandled error", status.error)
        end
    end
    if obj then status = obj end
    return status
end

function M.search(uri, cache, param, opts)
    local container
    local validation = M.internal.validate(uri, cache)
    if validation.message then return validation end
    opts = opts or {}
    opts.search_param = param
    uri = validation.uri
    container = validation.container
    return M.internal.find(uri, container, opts)
end

--- Reads contents from a container and returns them in the prescribed netman.api.read return format
--- @param uri string
---     The string uri to read. Can be a directory or file
--- @param cache Cache
---     The netman.api provided cache
--- @return table
---     @see :help netman.api.read for details on what this returns
function M.read(uri, cache)
    local container
    local validation = M.internal.validate(uri, cache)
    logger.debug("URI", uri, " -- Validation", validation)
    if validation.message then return validation end
    uri = validation.uri
    container = validation.container
    local _, stat = next(container:stat(uri, {M.internal.Container.CONSTANTS.STAT_FLAGS.TYPE}))
    if not stat then
        return {
            success = false,
            message = {
                message = string.format("%s doesn't exist", uri:to_string()),
                error = api_flags.ERRORS.ITEM_DOESNT_EXIST
            }
        }
    end
    -- If the container is running there is no reason we can't quickly stat the file in question...
    if stat.TYPE == 'directory' then
        return M.internal.read_directory(uri, container)
    else
        -- We don't support stream read type so its either a directory or a file...
        -- Idk maybe we change that if we allow archive reading but 🤷
        return M.internal.read_file(uri, container)
    end
end

function M.write(uri, cache, data)
    local container
    local validation = M.internal.validate(uri, cache)
    if validation.message then return validation end
    uri = validation.uri
    container = validation.container
    if uri.type == api_flags.ATTRIBUTES.DIRECTORY then
        local _ = container:mkdir(uri)
        if not _.success then
            return {
                success = false, message = { message = _.error }
            }
        end
        local _ = container:stat(uri)
        if not _ then
            return {
                success = false, message = { message = string.format("Unable to stat newly created %s", uri:to_string())}
            }
        end
        local _, _stat = next(_)
        return {
            success = true, uri = _stat.URI
        }
    end
    -- Lets make sure the file exists?
    local touch_status = container:touch(uri)
    if not touch_status.success then
        return {
            success = false, message = { message = touch_status.error or "touch failed with unknown error"}
        }
    end
    data = data or {}
    data = table.concat(data, '')
    local local_file = string.format("%s%s", local_files, uri.unique_name)
    local fh = io.open(local_file, 'w+')
    assert(fh, string.format("Unable to open local file %s for %s", local_file, uri:to_string('remote')))
    assert(fh:write(data), string.format("Unable to write to local file %s for %s", local_file, uri:to_string('remote')))
    assert(fh:flush(), string.format('Unable to save local file %s for %s', local_file, uri:to_string('remote')))
    assert(fh:close(), string.format("Unable to close local file %s for %s", local_file, uri:to_string('remote')))
    local _ = container:put(local_file, uri)
    if not _.success then
        return { uri = uri.uri, success = false, message = { message = _.error } }
    end
    return { success = true, uri = uri.uri }
end

function M.copy(uris, target_uri, cache)
    local container
    local validation = M.internal.validate(target_uri, cache)
    if validation.message then return validation end
    container = validation.container
    target_uri = validation.uri
    if type(uris) ~= 'table' then uris = {uris} end
    local validated_uris = {}
    for _, uri in ipairs(uris) do
        local __ = M.internal.validate(uri, cache)
        if __.error then return __ end
        if __.container ~= validation.container then
            return {
                success = false,
                message = {
                    message = string.format("%s and %s are not on the same container!", uri, target_uri)
                }
        }
        end
        table.insert(validated_uris, __.uri)
    end
    return container:cp(validated_uris, target_uri)
end

function M.move(uris, target_uri, cache)
    local container
    local validation = M.internal.validate(target_uri, cache)
    if validation.message then return validation end
    container = validation.container
    target_uri = validation.uri
    if type(uris) ~= 'table' then uris = {uris} end
    local validated_uris = {}
    for _, uri in ipairs(uris) do
        local __ = M.internal.validate(uri, cache)
        if __.error then return __ end
        if __.container ~= validation.container then
            return {
                success = false,
                message = {
                    message = string.format("%s and %s are not on the same container!", uri, target_uri)
                }
        }
        end
        table.insert(validated_uris, __.uri)
    end
    return container:mv(validated_uris, target_uri)
end

function M.delete(uri, cache)
    local container
    local validation = M.internal.validate(uri, cache)
    if validation.message then return validation end
    uri = validation.uri
    container = validation.container
    return container:rm(uri, {force = true})
end

function M.get_metadata(uri, cache)
    local container
    local validation = M.internal.validate(uri, cache)
    if validation.message then return validation end
    uri = validation.uri
    container = validation.container
    return container:stat(uri)
end

function M.update_metadata(uri, cache, _updates)
    -- TODO:
    local validation = M.internal.validate(uri, cache)
    if validation.message then return validation end
    -- TODO:
end

-- This will return all the containers on the system
function M.get_all_containers()
    local command = { 'podman', 'container', 'list', '--all', '--format',
        '{\"name\": {{json .Names}},\"status\": {{json .Status}}}' }
    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = shell:new(command, command_options):run()
    logger.trace(command_output)
    if command_output.exit_code ~= 0 then
        logger.warn(string.format("Received Error Code: %s", command_output.exit_code))
        return {}
    end
    local _containers = {}
    for _, item in ipairs(command_output.stdout) do
        local parsed_output = vim.fn.json_decode(item)
        table.insert(_containers, parsed_output)
    end
    return _containers
end

--- Returns the various containers that are currently available on the system
--- @param _config Configuration
--- @return table
---     Returns a 1 dimensional table containing the name of each available container
---@diagnostic disable-next-line: unused-local
function M.ui.get_hosts(_config)
    local containers = M.get_all_containers()
    local hosts = {}
    for _, container in ipairs(containers) do
        table.insert(hosts, container.name)
    end
    return hosts
end

--- Returns a list of details for a container.
--- @param _config Configuration
--- @param container_name string
--- @param cache Cache
--- @return table
---     Returns a 1 dimensional table with the following key value pairs in it
---     - NAME
---     - URI
---     - STATE
---     - OS
---@diagnostic disable-next-line: unused-local
function M.ui.get_host_details(_config, container_name, cache)
    local container = M.internal.Container:new(container_name, cache)
    local get_state = function()
        local state = container:current_status()
        local clean_state = ui_states.UNKNOWN
        if state == M.internal.Container.CONSTANTS.STATUS.ERROR then
            clean_state = ui_states.ERROR
        elseif state == M.internal.Container.CONSTANTS.STATUS.RUNNING then
            clean_state = ui_states.AVAILABLE
        elseif state == M.internal.Container.CONSTANTS.STATUS.NOT_RUNNING then
            clean_state = ui_states.STOPPED
        end
        return clean_state
    end
    local host_details = {
        NAME = container_name,
        OS = container.os:lower():match('^([a-z]+)'),
        URI = string.format("podman://%s/", container_name),
        STATE = get_state
    }
    return host_details
end

function M.archive.get(uris, cache, archive_dump_dir, available_compression_schemes)
    if type(uris) ~= 'table' or #uris == 0 then uris = {uris} end
    local container = nil
    local __ = {}
    for _, uri in ipairs(uris) do
        local validation = M.internal.validate(uri, cache)
        if validation.message then return validation end
        assert(container == nil or validation.container == container, string.format("Container mismatch for archive! %s != %s", container, validation.container))
        table.insert(__, validation.uri)

        container = validation.container
    end
    uris = __
    return container:archive(uris, archive_dump_dir, available_compression_schemes, cache)
end

function M.archive.put(uri, cache, archive, compression_scheme)
    assert(archive, string.format("Invalid Archive provided for upload to %s", uri))
    local container
    local validation = M.internal.validate(uri, cache)
    if validation.message then return validation end
    uri = validation.uri
    container = validation.container
    return container:extract(archive, uri, compression_scheme, cache)
end

function M.archive.schemes(uri, cache)
    assert(cache, string.format("No cache provided for archive scheme fetch of %s", uri))
    local container
    local validation = M.internal.validate(uri, cache)
    if validation.message then return validation end
    container = validation.container
    return container.archive_schemes
end

function M.close_connection(_uri, _cache)

end

return M
