-- TODO: Implement a container capabilities mechanic so we can take advantage of
-- certain distro traits if they exist
local log = require("netman.tools.utils").log
local notify = require("netman.tools.utils").notify
local api_flags = require("netman.tools.options").api
local string_generator = require("netman.tools.utils").generate_string
local local_files = require("netman.tools.utils").files_dir
local metadata_options = require("netman.tools.options").explorer.METADATA
local ui_states = require("netman.tools.options").ui.STATES
local shell = require("netman.tools.shell")
local command_flags = shell.CONSTANTS.FLAGS
local CACHE = require("netman.tools.cache")

local M = {
    internal = {},
    ui = {},
    archive = {}
}
-- Check if devicons exists. If not, unicode boi!
M.ui.icon = "🐋"
local success, web_devicons = pcall(require, "nvim-web-devicons")
if success then
    local devicon, _ = web_devicons.get_icon('dockerfile')
    M.ui.icon = devicon or M.ui.icon
end

local container_pattern  = "^([%a%c%d%s%-_%.]*)"
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

--- Creating the container object
--- An abstraction layer of _existing_ docker container instances
local Container = {
    CONSTANTS = {
        STATUS = {
            RUNNING = "RUNNING",
            NOT_RUNNING = "NOT RUNNING",
            INVALID = "INVALID",
            UNKNOWN = "UNKNOWN",
            ERROR = "ERROR"
        },
        -- Maximimum number of bytes we are willing to read in at once from a file
        IO_BYTE_LIMIT = 2 ^ 13,
        STAT_FLAGS = {
            MODE = 'MODE',
            BLOCKS = 'BLOCKS',
            BLKSIZE = 'BLKSIZE',
            MTIME_SEC = 'MTIME_SEC',
            USER = 'USER',
            GROUP = 'GROUP',
            INODE = 'INODE',
            PERMISSIONS = 'PERMISSIONS',
            SIZE = 'SIZE',
            TYPE = 'TYPE',
            NAME = 'NAME',
            RAW = 'RAW',
            URI = 'URI'
        }
    },
    internal = {
        DOCKER_ENABLED = false
    }
}
-- Creating the URI object
local URI = {}
M.internal.Container = Container
M.internal.URI = URI

-- Consider making all shell communication async?
function Container:new(container_name, provider_cache)
    assert(provider_cache, "No cache provided to create container object")
    if provider_cache:get_item(container_name) then
        -- Me!!!
        return provider_cache:get_item(container_name)
    end
    -- We do _not_ need to run this for every single container created as the machine running this isn't likely to change.
    -- And if somehow we lose the ability to interact with docker while we are in memory, we wouldn't know anyway because
    -- the container abstraction was already created. Besides, if that happens the user has bigger problems than
    -- if we can interact with docker or not
    if not Container.internal.DOCKER_ENABLED then
        -- Check if docker is installed??
        -- Check if the user can use docker
        local check_docker_command = { "docker", "-v" }
        local _ = { [command_flags.STDOUT_JOIN] = '', [command_flags.STDERR_JOIN] = '' }
        local __ = shell:new(check_docker_command, _):run()
        log.trace(__)
        if __.exit_code ~= 0 then
            local _error = "Unable to verify docker is available to run"
            log.warn(_error, { exit_code = __.exit_code, stderr = __.stderr })
            return {}
        end
        if __.stdout:match('Got permission denied while trying to connect to the Docker daemon socket at') then
            local _error = "User does not have permission to run docker commands"
            log.warn(_error, { exit_code = __.exit_code, stderr = __.stderr })
            return {}
        end
        Container.internal.DOCKER_ENABLED = true
    end
    local _container = {}
    self.__index = function(_table, _key)
        if _key == 'os' then
            return Container._get_os(_table)
        end

        if _key == 'archive_schemes' or _key == '_archive_commands' or _key == '_extract_commands' then
            local details = Container._get_archive_availability_details(_table)
            _table.archive_schemes = details.archive_schemes
            _table._extract_commands = details.extract_commands
            _table._archive_commands = details.archive_commands
            return _table[_key]
        end
        return self[_key]
    end

    setmetatable(_container, self)
    _container.name = container_name

    _container.__type = 'netman_provider_docker'
    _container.protocol = 'docker'
    -- These are all lazy loaded via the index function
    -- _container.os = ''
    -- _container._archive_commands = {}
    -- _container._extract_commands = {}
    -- _container.archive_schemes = {}
    _container.cache = CACHE:new(CACHE.FOREVER)
    -- Might be worth trying to establish the actual default shell?
    _container.console_command = {"docker", "exec", "-it", _container.name, "/bin/sh"}
    provider_cache:add_item(_container.name, _container)
    return _container
end

function Container:_get_os()
    log.trace(string.format("Checking OS For Container %s", self.name))
    local _get_os_command = 'cat /etc/*release* | grep -E "^NAME=" | cut -b 6-'
    local output = self:run_command(_get_os_command, {
        [command_flags.STDOUT_JOIN] = ''
    })
    if output.exit_code ~= 0 then
        log.warn(string.format("Unable to identify operating system for %s", self.name))
        return nil
    end
    return output.stdout:gsub('["\']', '')
end

function Container:_get_archive_availability_details()
    log.trace(string.format("Checking Available Archive Formats for %s", self.name))
    local output = self:run_command('tar --version', { [command_flags.STDERR_JOIN] = '' })
    if output.exit_code ~= 0 then
        -- complain about being unable to find archive details...
        log.warn(string.format("Unable to establish archive details for %s", self.name))
    end
    local schemes = {}
    local archive_commands = {}
    local extract_commands = {}
    -- Making the assumption that if tar is installed, so is gzip. You _should_ have tar...
    table.insert(schemes, 'tar.gz')
    table.insert(schemes, 'tar')
    -- Deal with the fact that tar may be busybox or GNU. They are different
    -- enough that we will need different compress commands :(
    local tar_type = output.stdout[1]
    if tar_type:match('busybox') then
        -- Found a busybox version of tar. Get ready for the fuckery!
        archive_commands['tar.gz'] = function(locations)
            local formatted_command = ''
            local pre_format_command = "%s (%s tar -cf - -C %s %s)"
            local header_offset = ''
            local first_pass = true
            for _, location in ipairs(locations) do
                assert(location.__type and location.__type == 'netman_uri',
                    string.format("%s is not a compatible netman uri", location))
                local parent = location:parent():to_string()
                local chain = ''
                if not first_pass then
                    header_offset = 'head -c -1024 &&'
                    chain = '|'
                end
                formatted_command = formatted_command ..
                    string.format(pre_format_command, chain, header_offset, parent,
                        location.path[#location.path])
                first_pass = false
            end
            formatted_command = formatted_command .. ' | gzip -9 -c -'
            return formatted_command
        end
    else
        -- GNU Tar. Ya!!!
        archive_commands['tar.gz'] = function(locations)
            local formatted_command = ''
            local pre_format_command = "%s (%s tar --blocking-factor 1 -cf - -C %s %s)"
            local header_offset = ''
            local first_pass = true
            for _, location in ipairs(locations) do
                assert(location.__type and location.__type == 'netman_uri',
                    string.format("%s is not a compatible netman uri", location))
                local parent = location:parent():to_string()
                local chain = ''
                if not first_pass then
                    header_offset = 'head -c -1024 &&'
                    chain = '|'
                end
                formatted_command = formatted_command ..
                    string.format(pre_format_command, chain, header_offset, parent,
                        location.path[#location.path])
                first_pass = false
            end
            formatted_command = formatted_command .. ' | gzip -9 -c -'
            return formatted_command
        end
    end
    extract_commands['tar.gz'] = function(location, archive)
        local pre_format_command = "tar -C %s -xzf %s"
        return string.format(pre_format_command, location:to_string(), archive)
    end
    archive_commands['tar'] = archive_commands['tar.gz']
    extract_commands['tar'] = extract_commands['tar.gz']
    return {
        archive_commands = archive_commands,
        extract_commands = extract_commands,
        archive_schemes  = schemes
    }
end

--- Runs the provided command inside the container
--- @param command string/table
---     Command can be either a string or table or strings
--- @param opts table | Optional
---     Default: {STDOUT_JOIN = '', STDERR_JOIN = ''}
---     A table of command options. @see netman.tools.shell for details. Additional key/value options
---     - no_shell
---         - If provided, the command will not be wrapped in a `/bin/sh -c` execution context. Note, this will be set if you provide a table for command
--- @return table
---     Returns a table with the following key value pairs
---     - exit_code: integer
---         - _Usually_ this is the exit_code of the command ran, though it may be -1 to indicate an error outside the command occured
---     - stderr: string/table
---         - The output from the STDERR pipe from the command
---     - stdout: string/table
---         - The output from the STDOUT pipe from the command
--- @example
---     local container = Container:new('ubuntu')
---     print(container:run_command({"cat", "/etc/*release*"}).stdout)
---         DISTRIB_ID=Ubuntu
---         DISTRIB_RELEASE=22.04
---         DISTRIB_CODENAME=jammy
---         ...
function Container:run_command(command, opts)
    -- It might be easier if we put some hooks into docker to
    -- listen for changes to the container...?
    opts = opts or {
        [command_flags.STDOUT_JOIN] = '',
        [command_flags.STDERR_JOIN] = ''
    }
    local _command = { "docker", "exec", self.name }
    if type(command) == 'string' then
        if not opts.no_shell then
            table.insert(_command, '/bin/sh')
            table.insert(_command, '-c')
        end
        table.insert(_command, command)
    elseif type(command) == 'table' then
        for _, _c in ipairs(command) do
            table.insert(_command, _c)
        end
    else
        log.error(string.format("I have no idea what I am supposed to do with %s", command),
            { type = type(command), command = command })
        return { exit_code = -1, stderr = "Invalid command passed to netman docker!", stdout = '' }
    end
    -- TODO: Consider just having one shell that is reused instead of making new and discarding each time?
    ---@diagnostic disable-next-line: missing-parameter
    local _shell = shell:new(_command, opts)
    ---@diagnostic disable-next-line: missing-parameter
    local _shell_output = _shell:run()
    log.trace(_shell:dump_self_to_table())
    return _shell_output
end

--- Retrieves the current status of the container from the docker cli/socket
--- @return string
---     Will return one of the following strings
---     - RUNNING
---     - NOT RUNNING
---     - ERROR
---     - INVALID
--- @example
---     print(Container:new('ubuntu'):current_status())
---         RUNNING
function Container:current_status()
    -- Maybe cache this in ourselves?
    local status = self.cache:get_item('status')
    if status and status == Container.CONSTANTS.STATUS.RUNNING then
        return status
    end
    local status_command = { 'docker', 'container', 'ls', '--all', '--format', 'table {{.Status}}', '--filter',
        string.format('name=%s', self.name) }
    local command_options = { [command_flags.STDERR_JOIN] = '' }
    ---@diagnostic disable-next-line: missing-parameter
    local command = shell:new(status_command, command_options)
    local command_output = command:run()
    log.trace(command:dump_self_to_table())


    status = Container.CONSTANTS.STATUS.NOT_RUNNING
    if command_output.exit_code ~= 0 then
        log.warn(string.format("Received non-0 exit code while checking status of container %s", self.name),
            { error = command_output.error, exit_code = command_output.exit_code })
        status = Container.CONSTANTS.STATUS.ERROR
        goto continue
    end
    if not command_output.stdout[2] then
        log.info(string.format("Container %s doesn't exist!", self.name))
        status = Container.CONSTANTS.STATUS.INVALID
        goto continue
    end
    if command_output.stdout[2]:match('^Up') then
        status = Container.CONSTANTS.STATUS.RUNNING
        goto continue
    end
    ::continue::
    self.cache:add_item('status', status, 20 * CACHE.SECOND)
    return status
end

--- Starts the container
--- @param opts table | Optional
---     If provided, this table will contain key value pairs that will modify how start is ran
---     Valid Key Value Pairs
---     - async: boolean
---         - If provided, we will start the container asynchronously, returning immediately. To get output from
---         this, it is recommended that you use `exit_callback`
---     - exit_callback: function
---         - If provided, we will call this after start instead of returning anything
---     - ignore_errors: boolean
---         - If provided, we wont complain if we get any errors while trying to start the container
--- @return table
---     Returns a table that contains the following key/value pairs
---     - success: boolean
---         A true/false to indicate if starting the container was successful
---     - error: string | Optional
---         The string error that was encountered during start. May not be present
--- @example
---     local container = Container:new('ubuntu')
---     container:start()
function Container:start(opts)
    opts = opts or {}
    local return_details = {}
    if self:current_status() == Container.CONSTANTS.STATUS.RUNNING then
        log.info(string.format("Container %s is already running", self.name))
        return { success = true }
    end
    local start_command = { 'docker', 'container', 'start', self.name }
    local finish_callback = function(command_output)
        log.trace(command_output)
        if command_output.exit_code ~= 0 and not opts.ignore_errors then
            local _error = string.format("Received non-0 exit code while trying to start container %s", self.name)
            log.warn(_error, { error = command_output.stderr, exit_code = command_output.exit_code })
            return_details = { error = _error, success = false}
            if opts.finish_callback then opts.finish_callback(return_details) end
            return
        end
        if self:current_status() == Container.CONSTANTS.STATUS.RUNNING then
            log.info(string.format("Successfully Started Container: %s", self.name))
            return_details = { success = true }
            if opts.finish_callback then opts.finish_callback(return_details) end
            return
        end
        local _error = string.format("Failed to start container: %s for reasons...?", self.name)
        return_details = { error = _error, success = false}
        log.warn(_error, { exit_code = command_output.exit_code, stderr = command_output.exit_code })
        if opts.finish_callback then opts.finish_callback(return_details) end
    end
    local command_options = {
        [command_flags.STDERR_JOIN] = '',
        [command_flags.EXIT_CALLBACK] = finish_callback
    }
    if opts.async then command_options[command_flags.ASYNC] = true end
    notify.info(string.format("Attempting to start %s", self.name))
    ---@diagnostic disable-next-line: missing-parameter
    shell:new(start_command, command_options):run()
    if not opts.async then return return_details end
end

--- Stops the container
--- @param opts table | Optional
---     Default: {}
---     If provided, the following key value pairs are acceptable options
---     - async: boolean
---         - If provided, we will stop asynchronously, returning immediately. To get results, also provide
---         a function with `finish_callback`
---     - force: boolean
---         - If provided, will force the container to stop (using kill instead of stop)
---     - timeout: integer
---         - If provided, will set the stop timeout to this integer. Ignored if force is provided
---     - finish_callback: function
---         - If provided, we will call this once complete.
---     If provided, this will forcible "kill" the container, instead of
---     allowing docker to gracefully stop it
--- @return table
---     Returns a table that contains the following key/value pairs
---     - success: boolean
---         A true/false to indicate if stopping the container was successful
---     - error: string | Optional
---         The string error that was encountered during stop. May not be present
---     NOTE: This table is _only_ provided to opts.finish_callback.
---     As this function performs asychronously, nothing is returned until its complete
--- @example
---     local container = Container:new('ubuntu')
---     container:stop()
function Container:stop(opts)
    if self:current_status() ~= Container.CONSTANTS.STATUS.RUNNING then
        log.info(string.format("Container %s is already stopped", self.name))
        return { success = true }
    end
    opts = opts or {}
    local return_details = {}
    local stop = "stop"
    local timeout = {}
    if opts.force then
        stop = "kill"
    end
    if opts.timeout and not opts.force then
        timeout = { "-t", 0 }
    end
    local stop_command = { 'docker', 'container', stop }
    for _, flag in ipairs(timeout) do
        table.insert(stop_command, flag)
    end
    table.insert(stop_command, self.name)
    local finish_callback = function(command_output)
        log.trace(command_output)
        if command_output.exit_code == nil then
            -- stop timed out
            local _error = string.format("Stop command timed out for %s", self.name)
            log.warn(_error, { error = command_output.stderr })
            return_details = { error = _error, success = false }
            if opts.finish_callback then opts.finish_callback(return_details) end
            return
        end
        if command_output.exit_code ~= 0 then
            local _error = string.format("Received non-0 exit code while trying to stop %s", self.name)
            log.warn(_error, { error = command_output.stderr, exit_code = command_output.exit_code })
            return_details = { error = _error, success = false }
            if opts.finish_callback then opts.finish_callback(return_details) end
            return
        end
        if self:current_status() == Container.CONSTANTS.STATUS.NOT_RUNNING then
            log.info(string.format("Successfully Stopped Container: %s", self.name))
            return_details = { success = true }
            if opts.finish_callback then opts.finish_callback(return_details) end
            return
        end
        local _error = string.format("Failed to properly stop container: %s for reasons...?", self.name)
        return_details = { error = _error, success = false }
        if opts.finish_callback then opts.finish_callback(return_details) end
    end
    local command_options = {
        [command_flags.STDERR_JOIN] = '',
        [command_flags.STDOUT_JOIN] = '',
        [command_flags.EXIT_CALLBACK] = finish_callback
    }
    if opts.async then command_options[command_flags.ASYNC] = true end
    notify.info(string.format("Attempting to stop %s", self.name))
    ---@diagnostic disable-next-line: missing-parameter
    shell:new(stop_command, command_options):run()
    if not opts.async then return return_details end
    -- Return is done via callback in the above `finish_callback` function
    ---@diagnostic disable-next-line: missing-return
end

--- Archives the provided location(s)
--- @param locations table
---     A table of Netman Docker URIs
--- @param archive_dir string
---     The directory to dump the archive in. Note, if opts.remote_dump is provided,
---     This will dump the archive remotely into the provided directory, creating it
---     if needed.
--- @param compatible_scheme_list table
---     A list of available archive types to chose from. By default, we will attempt
---     to use tar.gz unless thats not an option. But if you cant accept a gzipped tar,
---     what are you even doing with your life?
--- @param provider_cache table
---     The table that netman.api provides to you
--- @param opts table | Optional
---     Default: {}
---     A 2D table that can contain any of the following key, value pairs
---     - async: boolean
---         - If provided, we will perform the archive asychronously. It is recommended that 
---         this is used with finish_callback
---     - remote_dump: boolean
---         - If provided, indicates that the archive_dir is remote (on the container)
---     - finish_callback: function
---         - A function to call when the get is complete. Note, this is an asychronous function
---           so if you want to get output from the get, you will want to provide this
---     - output_file_name: string
---         - If provided, we will write to this file. By default, we will generate the file name and return
---         it in the exit_callback
--- @return table
---     NOTE: This will only return to the `finish_callback` function in opts as this is an asychronous function
---     Returns a table with the following key, value pairs
---     - archive_name string
---     - scheme string
---     - archive_path string
---         - If opts.remote_dump is provided, archive_path will be the URI to access the archive
---     - success boolean
---         - A boolean (t/f) of if the archive succedded or not
---     - error string | Optional
---         - Any errors that need to be displayed to the user
--- @example
---     -- This example assumes that you have received your cache from netman.api.
---     -- If that confuses you, please see netman.api.register_provider for details
---     -- or :help netman.api.providers
---     local cache = cache
---     local container = Container:new('ubuntu')
---     container:archive('/tmp', '/tmp/', {'tar.gz'}, cache)
function Container:archive(locations, archive_dir, compatible_scheme_list, provider_cache, opts)
    opts = opts or {}
    local return_details = {}
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    local compression_function = nil
    local selected_compression = nil
    for _, scheme in ipairs(self.archive_schemes) do
        if compression_function then break end
        local lower_scheme = scheme:lower()
        for _, comp_scheme in ipairs(compatible_scheme_list) do
            local lower_comp_scheme = comp_scheme:lower()
            if lower_scheme == lower_comp_scheme then
                compression_function = self._archive_commands[scheme]
                selected_compression = scheme
                break
            end
        end
    end
    assert(compression_function,
        string.format("Unable to find valid compression scheme in %s", table.concat(compatible_scheme_list, ', ')))
    local converted_locations = {}
    for _, location in ipairs(locations) do
        if type(location) == 'string' then
            if not location:match('^docker://') then
                -- A little bit of uri coalescing
                ---@diagnostic disable-next-line: cast-local-type
                location = string.format('docker://%s/%s', self.name, location)
            end
            location = URI:new(location)
        end
        assert(location.__type and location.__type == 'netman_uri',
            string.format("%s is not a valid Netman URI", location))
        table.insert(converted_locations, location)
    end
    locations = converted_locations
    local archive_name = opts.output_file_name or string.format("%s.%s", string_generator(10), selected_compression)
    local compress_command = compression_function(locations)
    local archive_path = string.format("%s/%s", archive_dir, archive_name)
    local finish_callback = function(output)
        log.trace(output)
        if output.exit_code ~= 0 then
            local _error = "Received non-0 exit code when trying to archive locations"
            log.warn(_error, { locations = locations, error = output.stderr, exit_code = output.exit_code })
            return_details =  { error = _error, success = false }
            if opts.finish_callback then opts.finish_callback(return_details) end
            return
        end
        return_details = {
            archive_name = archive_name,
            success = true,
            archive_path = archive_path,
            scheme = selected_compression
        }
        if opts.finish_callback then opts.finish_callback(return_details) end
    end
    local command_options = {
        [command_flags.STDERR_JOIN] = '',
        [command_flags.STDOUT_FILE_IS_BINARY] = true,
        [command_flags.STDOUT_FILE_OVERWRITE] = true,
        [command_flags.EXIT_CALLBACK] = finish_callback,
        -- Turning off stdout pipe as STDOUT is being dumped to a file
        [command_flags.STDOUT_PIPE_LIMIT] = 0
    }
    if opts.async then command_options[command_flags.ASYNC] = true end
    if opts.remote_dump then
        -- This probably doesn't work
        compress_command = string.format("mkdir -p %s && %s > %s/%s", archive_dir, compress_command, archive_dir,
            archive_name)
        archive_path = string.format("docker://%s/%s/%s", self.name, archive_dir, archive_name)
    else
        command_options[command_flags.STDOUT_FILE] = string.format("%s/%s", archive_dir, archive_name)
    end
    self:run_command(compress_command, command_options)
    if not opts.async then return return_details end
end

--- Extracts the provided archive into the target location in the container
--- @param archive string
---     The location of the archive to extract
--- @param target_dir URI
---     The location to extract to
--- @param scheme string
---     The scheme the archive is compressed with
--- @param provider_cache table
---     The cache that netman.api provided you
--- @param opts table | Optional
---     Default: {}
---     A list of options to be used when extracting. Available key/values are
---         - async: boolean
---             If provided, we will run the extraction asynchronously. It is recommended
---             that finish_callback is used with this
---         - ignore_errors: boolean
---             If provided, we will not output any errors we get
---         - remote_dump: boolean
---             Indicates that the archive is already on the container
---         - cleanup: boolean
---             Indicates that we need to delete the archive after successful extraction
---         - finish_callback: function
---             A function to call when the get is complete. Note, this is an asychronous function
---             so if you want to get output from the get, you will want to provide this
--- @return table
---     Returns a table that contains the following key/value pairs
---     - success: boolean
---         A true/false to indicate if the extraction was a success
---     - error: string | Optional
---         The string error that was encountered during extraction. May not be present
--- @example
---     -- This example assumes that you have received your cache from netman.api.
---     -- If that confuses you, please see netman.api.register_provider for details
---     -- or :help netman.api.providers
---     local cache = cache
---     -- Additionally, it assumes that `/tmp/some.tar.gz` exists on the local machine
---     local container = Container:new('ubuntu')
---     container:extract('/tmp/some.tar.gz', '/tmp/', 'tar.gz', cache)
---     -- TODO: Add an example of how to do an extract with a Pipe...
function Container:extract(archive, target_dir, scheme, provider_cache, opts)
    opts = opts or {}
    local return_details = {}
    local extraction_function = nil
    local lower_scheme = scheme:lower()
    for _, comp_scheme in ipairs(self.archive_schemes) do
        local lower_comp_scheme = comp_scheme:lower()
        if lower_comp_scheme == lower_scheme then
            extraction_function = self._extract_commands[scheme]
            break
        end
    end
    assert(extraction_function, string.format("Unable to find valid decompression scheme for %s", scheme))
    if type(target_dir) == 'string' then
        if not target_dir:match('^docker://') then
            -- A little bit of uri coalescing
            ---@diagnostic disable-next-line: cast-local-type
            target_dir = string.format('docker://%s/%s', self.name, target_dir)
        end
        target_dir = URI:new(target_dir)
    end
    assert(target_dir.__type and target_dir.__type == 'netman_uri',
        string.format("%s is not a valid netman uri", target_dir))
    -- If the archive isn't remote, we will want to craft a different command to extract it.
    local extract_command = nil
    local cleanup = nil
    self:mkdir(target_dir, { force = true })
    local finish_callback = function(command_output)
        log.trace(command_output)
        if command_output.exit_code ~= 0 then
            local _error = string.format("Unable to extract %s", archive)
            log.warn(_error, { exit_code = command_output.exit_code, error = command_output.stderr })
            return_details = { error = _error, success = false }
            if opts.finish_callback then opts.finish_callback(return_details) end
        end
        if cleanup then cleanup() end
        return_details = {success = true}
        if opts.finish_callback then opts.finish_callback(return_details) end
    end
    local command_options = {
        [command_flags.STDERR_JOIN] = '',
        [command_flags.ASYNC] = true,
        -- We don't want STDOUT for this
        [command_flags.STDOUT_PIPE_LIMIT] = 0,
        [command_flags.EXIT_CALLBACK] = finish_callback
    }
    -- if opts.async then command_options[command_flags.ASYNC] = true end
    if not opts.remote_dump then
        -- This is going to cat the contents of the archive into docker in an
        -- "interactive" session, which will pipe into the provided command.
        local fh = io.open(archive, 'r+b')
        if not fh then
            local _error = string.format("Unable to read %s", archive)
            if not opts.ignore_errors then log.warn(_error) end
            return { error = _error, success = false }
        end
        extract_command = {"docker", "exec", "-i", self.name, '/bin/sh', '-c', extraction_function(target_dir, '-')}
        if opts.cleanup then
            cleanup = function()
                vim.loop.fs_unlink(archive)
            end
        end
        local command = shell:new(extract_command, command_options)
        command:run()
        local stream = nil
        while true do
            -- NOTE:
            -- We will probably want to tweak this a bit to get better
            -- performance. Also keep in mind that we will eventually
            -- allow passing in PIPES to read straight through from
            -- STDOUT from on provider into STDIN in another provider
            stream = fh:read(Container.CONSTANTS.IO_BYTE_LIMIT)
            if not stream then break end
            command:write(stream)
        end
        fh:close()
        command:close()
    else
        extract_command = extraction_function(target_dir, archive)
        if opts.cleanup then
            cleanup = function()
                ---@diagnostic disable-next-line: param-type-mismatch, missing-parameter
                self:rm(archive, provider_cache)
            end
        end
        self:run_command(extract_command, command_options)
    end
    if not opts.async then return return_details end
end

--- Moves a location to another location in the container
--- @param locations table
---     The a table of string locations to move. Can be a files or directories
--- @param target_location string
---     The location to move to. Can be a file or directory
--- @param opts table | Optional
---     Default: {}
---     If provided, a table of options that can be used to modify how mv works
---     Valid Options
---     - ignore_errors: boolean
---         If provided, we will not report any errors received while attempting move
--- @return table
---     Returns a table that contains the following key/value pairs
---     - success: boolean
---         A true/false on if we successfully created the directory
---     - error: string | Optional
---         Any errors that occured during creation of the directory. Note, if opts.ignore_errors was provided, even if we get an error
---         it will not be returned. Ye be warned
--- @example
---     local container = Container:new('ubuntu')
---     container:mv('/tmp/testfile.txt', '/tmp/testfile2.txt')
function Container:mv(locations, target_location, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = {locations} end
    if target_location.__type and target_location.__type == 'netman_uri' then target_location = target_location:to_string() end
    local mv_command = { 'mv' }
    for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then
            location = location:to_string()
        end
        table.insert(mv_command, location)
    end
    table.insert(mv_command, '-t')
    table.insert(mv_command, target_location)
    mv_command = table.concat(mv_command, ' ')
    -- local mv_command = string.format("mv %s %s", location, target_location)
    local command_options = {
        [command_flags.STDERR_JOIN] = ''
    }
    local output = self:run_command(mv_command, command_options)
    if output.exit_code ~= 0 and not opts.ignore_errors then
        local message = string.format("Unable to move %s to %s", table.concat(locations, ' '), target_location)
        return { success = false, error = message }
    end
    return { success = true }
end

--- Touches a file in the container
--- @param locations table
---     A table of filesystem locations (as strings) touch
--- @param opts table | Optional
---     Default: {}
---     A list of key/value pair options that can be used to tailor how mkdir does "things". Valid key/value pairs are
---     - ignore_errors: boolean
---         - If provided, we will not complain one bit when things explode :)
--- @return table
---     Returns a table that contains the following key/value pairs
---     - success: boolean
---         A true/false on if we successfully created the directory
---     - error: string | Optional
---         Any errors that occured during creation of the directory. Note, if opts.ignore_errors was provided, even if we get an error
---         it will not be returned. Ye be warned
--- @example
---     local container = Container:new('ubuntu')
---     container:touch('/tmp/testfile.txt')
function Container:touch(locations, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    local touch_command = {"touch"}
     for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then location = location:to_string() end
        table.insert(touch_command, location)
    end
    local output = self:run_command(touch_command, { no_shell = true })
    if output.exit_code ~= 0 and not opts.ignore_errors then
        local _error = string.format("Unable to touch %s", table.concat(locations, ' '))
        log.warn(_error, { exit_code = output.exit_code, error = output.stderr })
        return { success = false, error = _error }
    end
    return { success = true }
end

--- Creates a directory in the container
--- @param locations table
---     A table of filesystem locations (as strings) create
--- @param opts table | Optional
---     Default: {}
---     A list of key/value pair options that can be used to tailor how mkdir does "things". Valid key/value pairs are
---     - ignore_errors: boolean
---         - If provided, we will not complain one bit when things explode :)
--- @return table
---     Returns a table that contains the following key/value pairs
---     - success: boolean
---         A true/false on if we successfully created the directory
---     - error: string | Optional
---         Any errors that occured during creation of the directory. Note, if opts.ignore_errors was provided, even if we get an error
---         it will not be returned. Ye be warned
--- @example
---     local container = Container:new('ubuntu')
---     container:mkdir('/tmp/testdir1')
function Container:mkdir(locations, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    -- It may be worth having this do something like
    -- test -d location || mkdir -p location
    -- instead, though I don't know that that is preferrable...?
    local mkdir_command = { "mkdir", "-p" }
    for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then location = location:to_string() end
        table.insert(mkdir_command, location)
    end
    local output = self:run_command(mkdir_command, { no_shell = true })
    if output.exit_code ~= 0 and not opts.ignore_errors then
        local _error = string.format("Unable to make %s", table.concat(locations, ' '))
        log.warn(_error, { exit_code = output.exit_code, error = output.stderr })
        return { success = false, error = _error }
    end
    return { success = true }
end

--- @param locations table
---     A table of netman uris to remove
--- @param opts table | Optional
---     Default: {}
---     A list of key/value pair options that can be used to tailor how mkdir does "things". Valid key/value pairs are
---     - force: boolean
---         - If provided, we will try to force the removal of the targets
---     - ignore_errors: boolean
---         - If provided, we will not complain one bit when things explode :)
--- @return table
---     Returns a table that contains the following key/value pairs
---     - success: boolean
---         A true/false on if we successfully created the directory
---     - error: string | Optional
---         Any errors that occured during creation of the directory. Note, if opts.ignore_errors was provided, even if we get an error
---         it will not be returned. Ye be warned
--- @example
---     local container = Container:new('ubuntu')
---     container:rm('/tmp/somedir')
---     -- You can also provide the `force` flag to force removal of a directory
---     container:rm('/tmp/somedir', {force=true})
---     -- You can also also provide the `ignore_errors` flag if you don't care if this
---     -- works or not
---     container:rm('/tmp/somedir', {ignore_errors=true})
function Container:rm(locations, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    local rm_command = {'rm', '-r'}
    if opts.force then table.insert(rm_command, '-f') end
    for _, location in ipairs(locations) do
        if type(location) == 'string' then
            if not location:match('^docker://') then
                -- A little bit of uri coalescing
                ---@diagnostic disable-next-line: cast-local-type
                location = string.format('docker://%s/%s', self.name, location)
            end
            location = URI:new(location)
        end
        assert(location.__type and location.__type == 'netman_uri', string.format("%s is not a valid netman uri", location))
        table.insert(rm_command, location:to_string())
    end
    local output = self:run_command(rm_command, { no_shell = true })
    if output.exit_code ~= 0 and not opts.ignore_errors then
        local _error = string.format("Unable to remove %s", table.concat(locations, ' '))
        log.error(_error, { exit_code = output.exit_code, error = output.stderr })
        return { success = false, error = _error }
    end
    return { success = true }
end

--- 
--- @param location string or URI
---     The location to find from
--- @param search_param string
---     The string to search for
--- @param opts table | Optional
---     - Default: {
---         pattern_type = 'iname',
---         follow_symlinks = true,
---         max_depth = 1,
---         min_depth = 1,
---         filesystems = true
---     }
---     If provided, options to parse into the find command
---     Valid keys
---     - search_param: string
---         - If provided will use this to filter find results
---     - pattern_type: string
---         - Used to match up the type of pattern provided. See find --help for details
---         - Valid values:
---             - name
---             - iname
---             - path
---             - ipath
---             - regex
---     - regex_type: string
---         @see https://www.gnu.org/software/findutils/manual/html_node/find_html/Regular-Expressions.html
---         for valid regex types. Note: regex_type will _not_ work on busybox (alpine) based containers
---     - follow_symlinks: boolean
---         - If provided, tells us to follow (or not) symlinks
---     - max_depth: integer
---         - If provided, used to specify the maximum depth to traverse our search
---     - min_depth: integer
---         - If provided, used to specify the minimum depth to traverse our search
---     - filesystems: boolean
---         - If provided, tells us to descend (or not) into other filesystems
---     - exec: string or function | Optional
---         - If provided, will be used as the `exec` flag with find.
---         Note: the `string` form of this needs to be a find compliant shell string. @see man find for details
---         Alternatively, you can provide a function that will be called with every match that find gets. Note, this will be significantly slower
---         than simply providing a shell string command, so if performance is your goal, use `string`
function Container:find(location, opts)
    local default_opts = {
        follow_symlinks = true,
        max_depth = 1,
        min_depth = 1,
        filesystems = true
    }
    opts = opts or {}
    -- Ensuring that sensible defaults are set in the event that options are provided and are missing defaults
    for key, value in pairs(default_opts) do
        if opts[key] == nil then opts[key] = value end
    end
    if location.__type and location.__type == 'netman_uri' then location = location:to_string() end
    local find_command = {'find', location}
    if opts.filesystems then table.insert(find_command, '-xdev') end
    if opts.max_depth then table.insert(find_command, '-maxdepth') table.insert(find_command, opts.max_depth) end
    if opts.min_depth then table.insert(find_command, '-mindepth') table.insert(find_command, opts.min_depth) end
    if opts.follow_symlinks then table.insert(find_command, '-follow') end
    if opts.search_param then
        if not opts.pattern_type then opts.pattern_type = 'iname' end
        if opts.pattern_type == 'name' then
            table.insert(find_command, '-name')
        elseif opts.pattern_type == 'iname' then
            table.insert(find_command, '-iname')
        elseif opts.pattern_type == 'path' then
            table.insert(find_command, '-path')
        elseif opts.pattern_type == 'ipath' then
            table.insert(find_command, '-ipath')
        elseif opts.pattern_type == 'regex' then
            table.insert(find_command, '-regex')
        else
            -- complain about invalid pattern type
            error(string.format("Invalid Find Pattern Type: %s. See :h netman.providers.docker.find for details", opts.pattern_type))
        end
        table.insert(find_command, opts.search_param)
    end
    local command_options = {
        [command_flags.STDERR_JOIN] = ''
    }
    if opts.exec then
        if type(opts.exec) == 'string' then
            table.insert(find_command, "-exec")
            table.insert(find_command, opts.exec .. " {} \\;")
        elseif type(opts.exec) == 'function' then
            command_options[command_flags.STDOUT_CALLBACK] = opts.exec
            command_options[command_flags.STDOUT_PIPE_LIMIT] = 0
        else
            -- complain about invalid exec type?
        end
    end
    local output =  self:run_command(table.concat(find_command, ' '), command_options)
    if output.exit_code ~= 0 then
        return {
            error = output.stderr
        }
    end
    return output.stdout
end

--- Uploads a file to the container, placing it in the provided location
--- @param file string
---     The string file location on the host
--- @param location URI
---     The location to put the file
--- @param opts table | Optional
---     Default: {}
---     A table containing options to alter the effect of `put`. Valid key/value pairs are
---     - new_file_name: string
---         - If provided, we will use this name for the file instead of its current name
---     - async: boolean
---         - If provided, we will perform this action asychronously. It is recommended to use this
---         with finish_callback
---     - ignore_errors: boolean
---         - If provided, we will not notify you of any errors that occur during the upload process.
---     - finish_callback: function
---         - A function to call when the put is complete. Note, this is an asychronous function
---         so if you want to get output from the get, you will want to provide this
--- @return table
---     A table will be returned with the following key/value pairs
---     - success: boolean
---         - A true/false to indicate if the upload was successful or not
---     - error: string
---         - A string error that occured during upload
--- @example
---     local container = Container:new('ubuntu')
---     container:put('/tmp/ubuntu.tar.gz', '/tmp/ubuntu')
function Container:put(file, location, opts)
    opts = opts or {}
    local return_details = {}
    assert(vim.loop.fs_stat(file), string.format("Unable to location %s", file))
    if type(location) == 'string' then
        if not location:match('^docker://') then
            -- A little bit of uri coalescing
            ---@diagnostic disable-next-line: cast-local-type
            location = string.format('docker://%s/%s', self.name, location)
        end
        location = URI:new(location)
    end
    assert(location.__type and location.__type == 'netman_uri', string.format("%s is not a valid netman URI", location))
    local file_name = location:to_string()
    if location.type ~= api_flags.ATTRIBUTES.DIRECTORY then
        local status, _stat = pcall(Container.stat, self, location, {Container.CONSTANTS.STAT_FLAGS.TYPE})
        -- Running this in protected mode because `location` may not exist. If it doesn't we will get an error,
        -- we don't actually care about the error we get, we are going to assume that the location doesn't exist
        -- if we get an error. Thus, error == gud
        if status == true and _stat[location:to_string()].TYPE ~= 'directory' then
            log.warn(string.format("Unable to verify that %s is a directory, you might see errors!", location:to_string()))
            file_name = location:to_string()
            location = location:parent()
        end
    end
    self:mkdir(location)
    if opts.new_file_name then
        file_name = string.format("%s/%s", location:to_string(), opts.new_file_name)
    end
    local finish_callback = function(command_output)
        log.trace(command_output)

        if command_output.exit_code ~= 0 and not opts.ignore_errors then
            local _error = string.format("Unable to upload %s", file)
            log.warn(_error, { exit_code = command_output.exit_code, error = command_output.stderr })
            return_details = { error = _error, success = false}
            if opts.finish_callback then opts.finish_callback(return_details) end
            return
        end
        return_details = { success = true}
        if opts.finish_callback then opts.finish_callback(return_details) end
    end
    local copy_command = { "docker", "cp", file, string.format("%s:%s", self.name, file_name) }
    local command_options = {
        [command_flags.STDOUT_JOIN] = '',
        [command_flags.STDERR_JOIN] = '',
        [command_flags.EXIT_CALLBACK] = finish_callback
    }
    if opts.async then
        command_options[command_flags.ASYNC] = true
    end
    ---@diagnostic disable-next-line: missing-parameter
    shell:new(copy_command, command_options):run()
    if not opts.async then return return_details end
end

--- Retrieves a file from the container and saves it in the output directory
--- NOTE: This can only be used to retrieve files. Directories must be archived with @see Container:archive
--- @param location URI
---     A netman URI of the location to download
--- @param output_dir string
---     The string filesystem path to download to
--- @param opts table | Optional
---     Default: {}
---     A table of key/value pairs that modify how get operates. Valid key/value pairs are
---     - async: boolean
---         - If provided, we will return immediately on start of fetching the file.
---         Note: If you use the async option, you are advised to also use `finish_callback`
---     - ignore_errors: boolean
---         - If provided, we will not report any errors that occur during the get process
---     - force: boolean
---         - If provided, uses a different method to pull down the file from the container.
---         Default process is to let docker's cp command handle this, however there are some
---         situations outlined in the docker documentation that would fail here. To counter that
---         force will instead cat the file from within the docker environment and pipe the STDOUT
---         into the file location provided
---     - finish_callback: function
---         - A function to call when the get is complete. Note, this is an asychronous function
---         so if you want to get output from the get, you will want to provide this
---     - new_file_name: string
---         - If provided, sets the downloaded file name to this. By default the file will maintain its
---         current filename
--- @return table
---     NOTE: This is provided to the `finish_callback` if its provided.
---     Returns a table that contains the following key/value pairs
---     - success: boolean
---         - A true/false indicating if the get was successful
---     - error: string | Optional
---         - A string of errors that occured during the get
--- @example
---     local container = Container:new('ubuntu')
---     container:get('/tmp/ubuntu.tar.gz', '/tmp/')
function Container:get(location, output_dir, opts)
    opts = opts or {}
    local return_details = {}
    assert(vim.loop.fs_stat(output_dir), string.format("Unable to locate %s. Is it a directory?", output_dir))
    if type(location) == 'string' then
        if not location:match('^docker://') then
            -- A little bit of uri coalescing
            ---@diagnostic disable-next-line: cast-local-type
            location = string.format('docker://%s/%s', self.name, location)
        end
        location = URI:new(location)
    end
    assert(location.__type and location.__type == 'netman_uri', string.format("%s is not a valid netman URI", location))
    local file_name = opts.new_file_name or location.path[#location.path]
    local finish_callback = function(command_output)
        log.trace(command_output)
        if command_output.exit_code ~= 0 and not opts.ignore_errors then
            local _error = string.format("Unable to download %s", location:to_string())
            log.warn(_error, { exit_code = command_output.exit_code, error = command_output.stderr })
            return_details = { error = _error, success = false}
            if opts.finish_callback then opts.finish_callback(return_details) end
            return
        end
        return_details = { success = true }
        if opts.finish_callback then opts.finish_callback(return_details) end
    end
    local copy_command = nil
    local command_options = {
        [command_flags.STDERR_JOIN] = '',
        [command_flags.EXIT_CALLBACK] = finish_callback
    }
    if opts.async then
        command_options[command_flags.ASYNC] = true
    end
    if opts.force then
        -- Shenanigans activate!
        command_options[command_flags.STDOUT_FILE] = string.format('%s/%s', output_dir, file_name)
        copy_command = { 'docker', 'exec', self.name, 'cat', location:to_string() }
    else
        copy_command = { "docker", "cp", string.format("%s:%s", self.name, location:to_string()),
            string.format("%s/%s", output_dir, file_name) }
        command_options[command_flags.STDOUT_JOIN] = ''
    end
    ---@diagnostic disable-next-line: missing-parameter
    shell:new(copy_command, command_options):run()
    if not opts.async then return return_details end
end

--- Takes a table of filesystem locations and returns the stat of them
--- @param locations table
---     - A table of filesystem locations
--- @param target_flags table | Optional
---     Default: Values from @see Container.CONSTANTS.STAT_FLAGS
---     - If provided, will return a table with only these keys and their respective values
---     - NOTE: You will _always_ get `NAME` back, even if you explicitly tell us not to return
---     it. We use it to order the stat entries on return, so deal with it
--- @return table
---     - Returns a table where each key is the uri's _local_ name, and its value is a stat table
---     containing at most, the following keys
---         - mode
---         - blocks
---         - blksize
---         - mtime_sec
---         - user
---         - group
---         - inode
---         - permissions
---         - size
---         - type
---         - name
---         - uri
---         - raw
--- @example
---     local container = Container:new('ubuntu')
---     print(vim.inspect(container:stat('/tmp')))
function Container:stat(locations, target_flags)
    -- Coerce into a table for iteration
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    local stat_flags = {
        '-L',
        '-c',
        'MODE=%f,BLOCKS=%b,BLKSIZE=%B,MTIME_SEC=%X,USER=%U,GROUP=%G,INODE=%i,PERMISSIONS=%a,SIZE=%s,TYPE=%F,NAME=%n' .. string.char(0)
    }
    local stat_command = { 'stat' }
    for _, flag in ipairs(stat_flags) do
        table.insert(stat_command, flag)
    end
    local __ = {}
    for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then location = location:to_string() end
        table.insert(__, location)
        table.insert(stat_command, location)
    end
    locations = __
    local stat_details = self:run_command(stat_command, {[command_flags.STDERR_JOIN] = ''})
    if stat_details.exit_code ~= 0 then
        -- Complain about stat failure??
        log.warn(string.format("Unable to get stat details for %s", table.concat(locations, ', '),
            { error = stat_details.stderr, exit_code = stat_details.exit_code }))
        return {}
    end
    -- Consider caching this for a short amount of time????
    return self:_stat_parse(stat_details.stdout, target_flags)
end

function Container:_stat_parse(stat_output, target_flags)
    if not target_flags then
        target_flags = {}
        for key, value in pairs(Container.CONSTANTS.STAT_FLAGS) do
            target_flags[key] = value
        end
    else
        local __ = {}
        for _, key in pairs(target_flags) do
            __[key:upper()] = Container.CONSTANTS.STAT_FLAGS[key]
        end
        if not __[Container.CONSTANTS.STAT_FLAGS['NAME']] then __[Container.CONSTANTS.STAT_FLAGS['NAME']] = Container.CONSTANTS.STAT_FLAGS.NAME end
        target_flags = __
    end
    if type(stat_output) == 'string' then stat_output = {stat_output} end
    local stat = {}
    for _, line in ipairs(stat_output) do
        local item = {}
        if target_flags[Container.CONSTANTS.STAT_FLAGS.RAW] then
            item[Container.CONSTANTS.STAT_FLAGS.RAW] = line
        end
        local _type = nil
        for _, pattern in ipairs(find_pattern_globs) do
            local key, value = line:match(pattern)
            line = line:gsub(pattern, '')
            if target_flags[key:upper()] then
                item[key:upper()] = value
            end
            if not _type and key:upper() == Container.CONSTANTS.STAT_FLAGS.TYPE then
                _type = value
            end
        end
        if target_flags[Container.CONSTANTS.STAT_FLAGS.URI] then
            item[Container.CONSTANTS.STAT_FLAGS.URI] = string.format(
                "docker://%s%s", self.name, item.NAME
            )
            if _type:upper() == 'DIRECTORY' and item.NAME:sub(-1, -1) ~= '/' then
                item[Container.CONSTANTS.STAT_FLAGS.URI] = item[Container.CONSTANTS.STAT_FLAGS.URI] .. '/'
            end
        end
        if target_flags[Container.CONSTANTS.STAT_FLAGS.TYPE] then
            if _type:upper() == 'DIRECTORY' then
                item['FIELD_TYPE'] = metadata_options.LINK
            elseif _type:upper() == 'REGULAR FILE' or _type:upper() == 'REGULAR EMPTY FILE' then
                item['FIELD_TYPE'] = metadata_options.DESTINATION
            end
        end
        item['ABSOLUTE_PATH'] = item.NAME
        local name = ''
        for _ in item.NAME:gmatch('[^/]+') do name = _ end
        item.NAME = name
        stat[item['ABSOLUTE_PATH']] = item
    end
    return stat
end

--- Executes remote chmod on provided locations
--- @param locations table
---     A table of filesystem string locations
--- @param targets table
---     A table that can contain any mix of the following strings
---     - user
---     - group
---     - all
---     - other
---     This will set the `ugao` part of the chmod command
--- @param permission_mods table
---     A table that can contain any mix of the following strings
---     - read
---     - write
---     - execute
---     This is the `rwx` part of the chmod command
--- @param opts table | Optional
---     Default: {}
---     If provided, a table that can alter how stat_mod operates. Valid Key Value Pairs are
---     - remove_mod: boolean
---         - If provided, will inverse and _remove_ the mods as opposed to adding them
---           This is how you would set `chmod u-r` to remove read access from a user (for example)
--- @return boolean
---     Returns a true/false boolean on if the change was successful or not
--- @example
---     local container = Container:new('ubuntu')
---     -- This is equivalent to chmod ug+r /tmp/ubuntu.tar.gz
---     container:stat_mod('/tmp/ubuntu.tar.gz', {'user', 'group'}, {'read'})
---     -- This is equivalent to chmod ug-w /tmp/ubuntu.tar.gz
---     container:stat_mod('/tmp/ubuntu.tar.gz', {'user', 'group'}, {'write'}, {remove_mod = true})
function Container:stat_mod(locations, targets, permission_mods, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    assert(targets, "Invalid user/group/nobody target provided")
    assert(permission_mods, "Invalid permission modification provided")
    local target = ''
    for _, _target in ipairs(targets) do
        -- Might as well give up a bit of memory to avoid
        -- doing this lower several times over
        local _lower_target = _target:lower()
        if _lower_target == 'user' or _lower_target == 'u' then
            target = target .. 'u'
        elseif _lower_target == 'group' or _lower_target == 'g' then
            target = target .. 'g'
        elseif _lower_target == 'all' or _lower_target == 'a' then
            target = target .. 'a'
        elseif _lower_target == 'other' or _lower_target == 'o' then
            target = target .. 'o'
        end
    end
    local permission = ''
    for _, _permission in ipairs(permission_mods) do
        local _lower_permission = _permission:lower()
        if _lower_permission == 'read' or _lower_permission == 'r' then
            permission = permission .. 'r'
        elseif _lower_permission == 'write' or _lower_permission == 'w' then
            permission = permission .. 'w'
        elseif _lower_permission == 'execute' or _lower_permission == 'x' then
            permission = permission .. 'x'
        end
    end
    local _mod = ''
    if opts.remove_mod then _mod = '-' else _mod = '+' end
    local command = string.format('chmod %s%s%s', target, _mod, permission)
    for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then location = location:to_string() end
        command = command .. string.format(" %s", location)
    end
    local output = self:run_command(command)
    if output.exit_code ~= 0 then
        log.warn("Received Error trying to modify permissions")
        return false
    end
    return true
end

-- This will return all the containers on the system
function Container.get_all_containers()
    local command = { 'docker', 'container', 'ls', '--all', '--format',
        '{\"name\": {{json .Names}},\"status\": {{json .Status}}}' }
    local command_options = {}
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = shell:new(command, command_options):run()
    log.trace(command_output)
    if command_output.exit_code ~= 0 then
        log.warn(string.format("Received Error Code: %s", command_output.exit_code))
        return {}
    end
    local _containers = {}
    for _, item in ipairs(command_output.stdout) do
        local parsed_output = vim.fn.json_decode(item)
        table.insert(_containers, parsed_output)
    end
    return _containers
end

--- URI Object functions
--------------------------------------
function URI:new(uri, cache)
    -- Parse URI
    assert(uri:match('docker://'), string.format("%s is not a valid docker uri. See :h netman-docker for details", uri))
    -- If a cache is provided and we are in it, return us!
    if cache and cache:get_item(uri) then return cache:get_item(uri) end
    local _uri = {}
    _uri.uri = uri
    uri = uri:gsub('docker://', '')
    _uri.container = uri:match(container_pattern)
    assert(_uri.container ~= nil,
        string.format("%s does not contain a valid container name. See :h netman-docker for details", uri))
    uri = uri:gsub(container_pattern, '')
    _uri.path = {}
    for part in uri:gmatch('([^/]+)') do
        table.insert(_uri.path, part)
    end
    if #_uri.path == 0 then
        table.insert(_uri.path, '/')
    end
    if uri:sub(-1, -1) == '/' then
        -- TODO: Consider using the container's `stat` method to check
        -- the metadata for the URI instead of string guessing?
        _uri.type = api_flags.ATTRIBUTES.DIRECTORY
        _uri.return_type = api_flags.READ_TYPE.EXPLORE
    else
        _uri.type = api_flags.ATTRIBUTES.FILE
        _uri.return_type = api_flags.READ_TYPE.FILE
        _uri.extension = '.' .. _uri.path[#_uri.path]:match('[^%.]+$')
        -- Some quick jank to ensure that things like tar.gz are caught properly
        local tar_override = _uri.path[#_uri.path]:match('%.tar%.[a-z]+$')
        if tar_override then _uri.extension = tar_override end
        _uri.unique_name = string.format("%s%s", string_generator(11), _uri.extension)
    end
    _uri.__type = 'netman_uri'
    setmetatable(_uri, self)
    self.__index = self
    if cache then cache:add_item(uri, _uri) end
    return _uri
end

--- Returns ourselves in string form
--- @param type string | Optional
---     Default: 'local'
---     Specifies the type of uri to return. Valid options are
---     - 'local'
---     - 'remote'
--- @return string
--- A URI will be returned in either a local (on container path) format, or
--- a remote format. Examples
--- - local
---     - /bin/sh
--- - remote
---     - docker://container/bin/sh
function URI:to_string(type)
    if not type then type = 'local' end
    local _path = ''
    if type == 'local' then
        _path = table.concat(self.path, '/')
        if not _path then _path = '/' end
        if _path:sub(1, 1) ~= '/' then _path = '/' .. _path end
        if self.type == api_flags.ATTRIBUTES.DIRECTORY and _path:sub(-1, -1) ~= '/' then
            _path = _path .. '/'
        end
    else
        _path = self.uri
    end
    return _path
end

--- Returns a URI object of our parent
--- @return URI
function URI:parent()
    local _path = {}
    for _, _item in ipairs(self.path) do
        table.insert(_path, _item)
    end
    local tail = table.remove(_path, #_path)
    -- If this is a shell variable, we have no idea what it could be or what it will expand to,
    -- so just use generic `..`
    if tail:match('^%$') then
        table.insert(_path, tail)
        table.insert(_path, '..')
    end
    if #_path == 0 then _path = { '/' } end

    return URI:new(
        string.format("docker://%s/%s", self.container.name, table.concat(_path, '/') .. '/')
    )
end

M.name = 'docker'
M.protocol_patterns = {'docker'}
M.version = 0.2

function M.internal.validate(uri, cache)
    assert(cache, string.format("No cache provided for read of %s",  uri))
    ---@diagnostic disable-next-line: cast-local-type
    uri = M.internal.URI:new(uri, cache)
    local container = M.internal.Container:new(uri.container, cache)
    -- Is the container running???
    if container:current_status() ~= M.internal.Container.CONSTANTS.STATUS.RUNNING then
        return {
            error = {
                message = string.format("%s is not running. Would you like to start it? [Y/n] ", container.name),
                default = 'Y',
                callback = function(response)
                   if response:match('^[yY]') then
                        local started = container:start()
                        if started.success then
                            notify.info(string.format("%s successfully started!", container.name))
                            return {retry = true}
                        else
                            return {retry = false, error=started.error}
                        end
                    else
                        log.info(string.format("Not starting container %s", container.name))
                        return {retry = false}
                    end
                end
            }
        }
    end
    return {uri = uri, container = container}
end

function M.internal.read_directory(uri, container)
    local raw_children = container:find(uri,
        { exec = 'stat -L -c MODE=%f,BLOCKS=%b,BLKSIZE=%B,MTIME_SEC=%X,USER=%U,GROUP=%G,INODE=%i,PERMISSIONS=%a,SIZE=%s,TYPE=%F,NAME=%n' }
    )
    if raw_children.error then
        -- Something happened during find.
        if raw_children.error:match('[pP]ermission%s+[dD]enied') then
            return {
                success = false,
                error = {
                    message = string.format("Permission Denied when accessing %s", uri:to_string())
                }
            }
        end
        -- Handle other errors as we find them
        return {
            success = false,
            error = raw_children.error
        }
    end
    local children = container:_stat_parse(raw_children)
    local _ = {}
    for child, metadata in pairs(children) do
        _[metadata.URI] = {
            URI = metadata.URI,
            FIELD_TYPE = metadata.FIELD_TYPE,
            NAME = metadata.NAME,
            -- Child will always be the absolute path, and its ever so slightly cheaper to do a straight memory reference as opposed
            -- to a hash lookup and memory reference
            ABSOLUTE_PATH = child,
            METADATA = metadata
        }
    end
    return {
        success = true,
        data = _,
        type = api_flags.READ_TYPE.EXPLORE
    }
end

function M.internal.read_file(uri, container)
    local status = container:get(uri, local_files, {new_file_name = uri.unique_name})
    if status.success then
        return {
            success = true,
            data = {
                local_path = string.format("%s%s", local_files, uri.unique_name),
                origin_path = uri:to_string()
            },
            type = api_flags.READ_TYPE.FILE
        }
    else
        return status
    end
end

--- Reads contents from a container and returns them in the prescribed netman.api.read return format
--- @param uri string
---     The string uri to read. Can be a directory or file
--- @param cache Cache
---     The netman.api provided cache
--- @return table
---     @see :help netman.api.read for details on what this returns
function M.read(uri, cache)
    local container = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    container = validation.container
    local _, stat = next(container:stat(uri, {M.internal.Container.CONSTANTS.STAT_FLAGS.TYPE}))
    if not stat then
        return {
            success = false,
            error = {
                message = string.format("%s doesn't exist", uri:to_string())
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
    local container = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    container = validation.container
    if uri.type == api_flags.ATTRIBUTES.DIRECTORY then
        return container:mkdir(uri)
    end
    -- Lets make sure the file exists?
    container:touch(uri)
    data = data or {}
    data = table.concat(data, '')
    local local_file = string.format("%s%s", local_files, uri.unique_name)
    local fh = io.open(local_file, 'w+')
    assert(fh, string.format("Unable to open local file %s for %s", local_file, uri:to_string('remote')))
    assert(fh:write(data), string.format("Unable to write to local file %s for %s", local_file, uri:to_string('remote')))
    assert(fh:flush(), string.format('Unable to save local file %s for %s', local_file, uri:to_string('remote')))
    assert(fh:close(), string.format("Unable to close local file %s for %s", local_file, uri:to_string('remote')))
    return container:put(local_file, uri)
end

function M.move(uris, target_uri, cache)
    local container = nil
    local validation = M.internal.validate(target_uri, cache)
    if validation.error then return validation end
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
                error = {
                    message = string.format("%s and %s are not on the same container!", uri, target_uri)
                }
        }
        end
        table.insert(validated_uris, __.uri)
    end
    return container:mv(validated_uris, target_uri)
end

function M.delete(uri, cache)
    local container = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    container = validation.container
    return container:rm(uri, {force = true})
end

function M.get_metadata(uri, cache)
    local container = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    container = validation.container
    return container:stat(uri)
end

function M.update_metadata(uri, cache, updates)
    -- TODO:
    local container = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    container = validation.container

    -- TODO:
end

--- Returns the various containers that are currently available on the system
--- @param config Configuration
--- @param cache Cache
--- @return table
---     Returns a 1 dimensional table containing the name of each available container
---@diagnostic disable-next-line: unused-local
function M.ui.get_hosts(config)
    local containers = M.internal.Container.get_all_containers()
    local hosts = {}
    for _, container in ipairs(containers) do
        table.insert(hosts, container.name)
    end
    return hosts
end

--- Returns a list of details for a container.
--- @param config Configuration
--- @param container_name string
--- @param cache Cache
--- @return table
---     Returns a 1 dimensional table with the following key value pairs in it
---     - NAME
---     - URI
---     - STATE
---@diagnostic disable-next-line: unused-local
function M.ui.get_host_details(config, container_name, cache)
    local container = M.internal.Container:new(container_name, cache)
    local state = container:current_status()
    local host_details = {
        NAME = container_name,
        -- OS = container.os,
        URI = string.format("docker://%s/", container_name)
    }
    if stat == M.internal.Container.CONSTANTS.STATUS.ERROR then
        host_details.STATE= ui_states.ERROR
    elseif state == M.internal.Container.CONSTANTS.STATUS.RUNNING then
        host_details.STATE = ui_states.AVAILABLE
    else
        host_details.STATE = ui_states.UNKNOWN
    end
    log.trace(host_details)
    return host_details
end

function M.archive.get(uris, cache, archive_dump_dir, available_compression_schemes)
    if type(uris) ~= 'table' or #uris == 0 then uris = {uris} end
    local container = nil
    local __ = {}
    for _, uri in ipairs(uris) do
        local validation = M.internal.validate(uri, cache)
        if validation.error then return validation end
        assert(container == nil or validation.container == container, string.format("Container mismatch for archive! %s != %s", container, validation.container))
        table.insert(__, validation.uri)

        container = validation.container
    end
    uris = __
    return container:archive(uris, archive_dump_dir, available_compression_schemes, cache)
end

function M.archive.put(uri, cache, archive, compression_scheme)
    assert(archive, string.format("Invalid Archive provided for upload to %s", uri))
    local container = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    container = validation.container
    return container:extract(archive, uri, compression_scheme, cache)
end

function M.archive.schemes(uri, cache)
    assert(cache, string.format("No cache provided for archive scheme fetch of %s", uri))
    local container = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    container = validation.container
    return container.archive_schemes
end

function M.init()
    -- Check if docker is installed??
    -- Check if the user can use docker
    local check_docker_command = { "docker", "-v" }
    local _ = { [command_flags.STDOUT_JOIN] = '', [command_flags.STDERR_JOIN] = '' }
    local __ = shell:new(check_docker_command, _):run()
    log.trace(__)
    if __.exit_code ~= 0 then
        local _error = "Unable to verify docker is available to run"
        log.warn(_error, { exit_code = __.exit_code, stderr = __.stderr })
        return false
    end
    if __.stdout:match('Got permission denied while trying to connect to the Docker daemon socket at') then
        local _error = "User does not have permission to run docker commands"
        log.warn(_error, { exit_code = __.exit_code, stderr = __.stderr })
        return false
    end
    -- Might as well set this here too since we have the ability
    M.internal.Container.internal.DOCKER_ENABLED = true
    return true
end

function M.close_connection()

end

return M
