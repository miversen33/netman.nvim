local JSON = require("netman.tools.parsers.json")
local socket_files = require("netman.tools.utils").socket_dir
local CACHE = require("netman.tools.cache")
local metadata_options = require("netman.tools.options").explorer.METADATA
local api_flags = require("netman.tools.options").api
local string_generator = require("netman.tools.utils").generate_string
local shell = require("netman.tools.shell")
local command_flags = shell.CONSTANTS.FLAGS
local local_files = require("netman.tools.utils").files_dir
local utils = require("netman.tools.utils")

local logger = require("netman.tools.utils").get_provider_logger()

local HOST_MATCH_GLOB = "^[%s]*Host[%s=](.*)"
local HOST_ITEM_GLOB = "^[%s]*([^%s]+)[%s]*(.*)$"

local find_pattern_globs = {
    '^(MODE)=(>?)([%d%a]+),',
    '^(BLOCKS)=(>?)([%d]+),',
    '^(BLKSIZE)=(>?)([%d]+),',
    '^(MTIME_SEC)=(>?)([%d]+),',
    '^(USER)=(>?)([%w%-._]+),',
    '^(GROUP)=(>?)([%w%s%-._]+),',
    '^(INODE)=(>?)([%d]+),',
    '^(PERMISSIONS)=(>?)([%d]+),',
    '^(SIZE)=(>?)([%d]+),',
    '^(TYPE)=(>?)([%l%s]+),',
    '^(NAME)=(>?)(.*)$'
}

local M = {}
M.protocol_patterns = { 'ssh', 'scp', 'sftp' }
M.name = 'ssh'
M.version = 0.2
M.internal = {}
M.archive = {}

M.ui = {
    icon = ""
}

local SSH = {
    CONSTANTS = {
        -- Maximum number of bytes we are willing to read in at once from a file
        IO_BYTE_LIMIT = 2 ^ 13,
        STAT_FLAGS = {
            ABSOLUTE_PATH = 'ABSOLUTE_PATH',
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
            URI = 'URI'
        },
        SSH_CONNECTION_TIMEOUT = 10,
        SSH_SOCKET_FILE_NAME = '%C', -- Much more compressed way to represent the "same" connection details
        SSH_PROTO_GLOB = '^([sfthcp]+)://',
        MKDIR_UNKNOWN_ERROR = 'mkdir failed with unknown error'
    },
    internal = {
        -- TODO: Set these to false
        SSH_AVAILABLE = true,
        SCP_AVAILABLE = true
    }

}
local URI = {}
M.internal.SSH = SSH
M.internal.URI = URI

--- Creates new SSH abstraction object
--- @param auth_details table
---     The authentication details for this SSH connection.
---     Valid Key Value pairs
---     - host: string
---     - user: string | nil
---     - port: interger | nil
---     - password: string | nil (only implemented for systems that have sshpass installed)
---     - key: string | nil (not implemented)
---     - passphrase: string | nil (not implemented)
--- @param provider_cache cache
---     The netman api provided cache.
---     If that confuses you, please see netman.api.register_provider for details
function SSH:new(auth_details, provider_cache)
    -- TODO: Add password support????
    assert(auth_details, "No authorization details provided for new ssh object. h: netman.provider.ssh.new")
    assert(provider_cache, "No cache provided for SSH object. h: netman.providers.ssh.new")
    assert(utils.os_has('ssh'), "SSH not available on this system!")
    if type(auth_details) == 'string' then
        if auth_details:sub(-1, -1) ~= '/' then
            -- A bit of common error correction to ensure that the string is a valid URI
            auth_details = auth_details .. '/'
        end
        if not auth_details:match(SSH.CONSTANTS.SSH_PROTO_GLOB) then
            -- The URI is likely just a username/hostname. We won't make that assumption,
            -- however we will prepend `ssh://` to the front of it
            auth_details = "ssh://" .. auth_details
        end
        local new_auth_details = URI:new(auth_details, provider_cache)
        assert(new_auth_details,
            string.format("Unable to parse %s into a valid SSH URI. h: netman.providers.ssh.new", auth_details))
        auth_details = new_auth_details
    end
    -- Yes I know that this means we will end up with weird keys like
    -- @somehost:
    -- I also know that I don't care. Its unique enough to the host details
    local cache_key = string.format("%s@%s:%s", auth_details.user, auth_details.host, auth_details.port)
    if provider_cache:get_item(cache_key) then
        return provider_cache:get_item(cache_key)
    end
    local _ssh = {}
    local ssh_config = require("netman.api").internal.get_config('netman.providers.ssh'):get('hosts')[auth_details.host]
    _ssh.protocol = 'ssh'
    _ssh._auth_details = auth_details
    _ssh.host = _ssh._auth_details.host
    _ssh.pass = _ssh._auth_details.password or ssh_config.password or ''
    _ssh.user = _ssh._auth_details.user or ssh_config.user or ''
    _ssh.port = _ssh._auth_details.port or ssh_config.port or ''
    _ssh.key  = _ssh._auth_details.key or ssh_config.identityfile or ''    _ssh.__type = 'netman_provider_ssh'
    _ssh.cache = CACHE:new(CACHE.FOREVER)

    _ssh.console_command = { 'ssh' }
    _ssh._put_command = { 'scp' }
    -- Intentionally leaving off the command to use for `get` as you could use either sftp or scp.
    -- The flags are the same regardless though
    _ssh._get_command = {}
    if _ssh.port:len() > 0 then
        table.insert(_ssh.console_command, '-p')
        table.insert(_ssh._put_command, '-P')
        table.insert(_ssh.console_command, _ssh.port)
        table.insert(_ssh._put_command, _ssh.port)
    end
    if _ssh.key:len() > 0 then
        table.insert(_ssh.console_command, '-i')
        table.insert(_ssh._put_command, '-i')
        table.insert(_ssh.console_command, _ssh.key)
        table.insert(_ssh._put_command, _ssh.key)
    end
    if ssh_config.proxyjump then
        table.insert(_ssh.console_command, '-J')
        table.insert(_ssh.console_command, ssh_config.proxyjump)
        table.insert(_ssh._put_command, '-J')
        table.insert(_ssh._put_command, ssh_config.proxyjump)
        table.insert(_ssh._get_command, '-J')
        table.insert(_ssh._get_command, ssh_config.proxyjump)
    end

    if utils.os ~= 'windows' then
        -- Sorry Windows users, windows doesn't support ssh multiplexing :(
        table.insert(_ssh.console_command, '-o')
        table.insert(_ssh.console_command, 'ControlMaster=auto')
        table.insert(_ssh._put_command, '-o')
        table.insert(_ssh._put_command, 'ControlMaster=auto')

        table.insert(_ssh.console_command, '-o')
        table.insert(_ssh.console_command,
        string.format('ControlPath="%s%s"', socket_files, SSH.CONSTANTS.SSH_SOCKET_FILE_NAME))
        table.insert(_ssh._put_command, '-o')
        table.insert(_ssh._put_command,
            string.format('ControlPath="%s%s"', socket_files, SSH.CONSTANTS.SSH_SOCKET_FILE_NAME))

        table.insert(_ssh.console_command, '-o')
        table.insert(_ssh.console_command, string.format('ControlPersist=%s', SSH.CONSTANTS.SSH_CONNECTION_TIMEOUT))
        table.insert(_ssh._put_command, '-o')
        table.insert(_ssh._put_command, string.format('ControlPersist=%s', SSH.CONSTANTS.SSH_CONNECTION_TIMEOUT))
    end
    if _ssh._auth_details.user:len() > 0 then
        local _ = string.format('%s@%s', _ssh._auth_details.user, _ssh._auth_details.host)
        table.insert(_ssh.console_command, _)
        table.insert(_ssh._put_command, _)
    else
        table.insert(_ssh.console_command, _ssh._auth_details.host)
        table.insert(_ssh._put_command, _ssh._auth_details.host)
    end

    for _, flag in ipairs(_ssh._put_command) do
        table.insert(_ssh._get_command, flag)
    end
    -- Popping the head of the get command off as we need to dynamically define
    -- if we want to use scp or sftp, and we need to tell the respective command
    -- where to save the file to
    table.remove(_ssh._get_command, 1)

    self.__index = function(_table, _key)
        if _key == 'os' then
            return SSH._get_os(_table)
        end
        if _key == 'home' then
            return SSH._get_user_home(_table)
        end

        if _key == 'archive_schemes' or _key == '_archive_commands' or _key == '_extract_commands' then
            local details = SSH._get_archive_availability_details(_table)
            _table.archive_schemes = details.archive_schemes
            _table._extract_commands = details.extract_commands
            _table._archive_commands = details.archive_commands
            return _table[_key]
        end
        return self[_key]
    end
    -- These are all lazy loaded via the index function
    -- _ssh.os = ''
    -- _ssh.home = ''
    -- _ssh._archive_commands = {}
    -- _ssh._extract_commands = {}
    -- _ssh.archive_schemes = {}
    setmetatable(_ssh, self)
    provider_cache:add_item(cache_key, _ssh)
    return _ssh
end

function SSH:_set_user_password(new_password)
    if not new_password then
        logger.info("Removing saved password for host", self.host)
        if self.console_command[1] == 'sshpass' then
            table.remove(self.console_command, 1)
            table.remove(self.console_command, 1)
            table.remove(self.console_command, 1)
        end
        if self._put_command[1] == 'sshpass' then
            table.remove(self._put_command, 1)
            table.remove(self._put_command, 1)
            table.remove(self._put_command, 1)
        end
    else
        logger.warn("You should really use an ssh key instead of a password...")
        if utils.os_has("sshpass") then
            table.insert(self.console_command, 1, new_password)
            table.insert(self.console_command, 1, "-p")
            table.insert(self.console_command, 1, "sshpass")
            table.insert(self._put_command, 1, new_password)
            table.insert(self._put_command, 1, "-p")
            table.insert(self._put_command, 1, "sshpass")
        else
            logger.warn("SSH connection requested using password auth but sshpass is not available on this system!")
        end
    end
end

function SSH:_get_os()
    logger.trace(string.format("Checking OS For Host %s", self.host))
    local _get_os_command = 'cat /etc/*release* | grep -E "^NAME=" | cut -b 6-'
    local output = self:run_command(_get_os_command, {
        [command_flags.STDOUT_JOIN] = '',
        [command_flags.STDERR_JOIN] = ''
    })
    if output.exit_code ~= 0 then
        logger.warn(string.format("Unable to identify operating system for %s", self.host))
        return "Unknown"
    end
    return output.stdout:gsub('["\']', '')
end

function SSH:_get_archive_availability_details()
    logger.trace(string.format("Checking Available Archive Formats for %s", self.host))
    local output = self:run_command('tar --version', { [command_flags.STDERR_JOIN] = '' })
    if output.exit_code ~= 0 then
        -- complain about being unable to find archive details...
        logger.warn(string.format("Unable to establish archive details for %s", self.name))
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
        local pre_format_command = "tar -C %s -oxzf %s"
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

function SSH:_create_uri(location)
    location = location or '/'
    local _ = location
    local is_relative = false
    if location:match('~/') then
        location = location:gsub('~/', '/')
        is_relative = true
    end
    if location:match('^%$HOME/') then
        location = location:gsub('^%$HOME/', '/')
        is_relative = true
    end
    if not is_relative then
        if location:sub(1, 1) ~= '/' then
            location = string.format('///%s', location)
        else
            location = string.format('//%s', location)
        end
    end
    return string.format('ssh://%s%s', self.host, location)
end

--- Runs the provided command over the SSH pipe
--- @param command string/table
---     Command can be either a string or table or strings
--- @param opts table | nil
---     Default: {STDOUT_JOIN = '', STDERR_JOIN = ''}
---     A table of command options. @see netman.tools.shell for details. Additional key/value options
---     - no_shell
---         - If provided, the command will not be wrapped in a `/bin/sh -c` execution context. Note, this will be set if you provide a table for command
--- @return table
---     @see netman.tools.shell:run
---     Returns exactly what shell returns
function SSH:run_command(command, opts)
    -- It might be easier if we put some hooks into host to
    -- listen for changes to the host...?
    opts = opts or {
        [command_flags.STDOUT_JOIN] = '',
        [command_flags.STDERR_JOIN] = ''
    }
    local pre_command = {}
    if type(command) == 'string' then
        if not opts.no_shell then
            table.insert(pre_command, '/bin/sh')
            table.insert(pre_command, '-c')
            table.insert(pre_command, string.format("'%s'", command))
        else
            table.insert(pre_command, command)
        end
    elseif type(command) == 'table' then
        for _, _c in ipairs(command) do
            table.insert(pre_command, _c)
        end
    else
        logger.error(string.format("I have no idea what I am supposed to do with %s", command),
            { type = type(command), command = command })
        return { exit_code = -1, stderr = "Invalid command passed to netman ssh !", stdout = '' }
    end
    local _command = {}
    -- Copying the console command to a new table so we can add shit to it
    for _, __ in ipairs(self.console_command) do
        table.insert(_command, __)
    end
    table.insert(_command, table.concat(pre_command, ' '))
    -- TODO: Consider just having one shell that is reused instead of making new and discarding each time?
    ---@diagnostic disable-next-line: missing-parameter
    local _shell = shell:new(_command, opts)
    ---@diagnostic disable-next-line: missing-parameter
    local _shell_output = _shell:run()
    logger.trace2(_shell:dump_self_to_table())
    return _shell_output
end

--- Archives the provided location(s)
--- @param locations table
---     A table of Netman SSH URIs
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
--- @param opts table | nil
---     Default: {}
---     A 2D table that can contain any of the following key, value pairs
---     - async: boolean
---         - If provided, we will perform the archive asychronously. It is recommended that
---         this is used with finish_callback
---     - remote_dump: boolean
---         - If provided, indicates that the archive_dir is remote (on the host)
---     - finish_callback: function
---         - A function to call when the get is complete. Note, this is an asychronous function
---           so if you want to get output from the get, you will want to provide this
---     - output_file_name: string
---         - If provided, we will write to this file. By default, we will generate the file name and return
---         it in the exit_callback
--- @return table
---     TODO: Add details about async return
---     NOTE: This will only return to the `finish_callback` function in opts as this is an asychronous function
---     Returns a table with the following key, value pairs
---     - archive_name string
---     - scheme string
---     - archive_path string
---         - If opts.remote_dump is provided, archive_path will be the URI to access the archive
---     - success boolean
---         - A boolean (t/f) of if the archive succedded or not
---     - error string | nil
---         - Any errors that need to be displayed to the user
--- @example
---     -- This example assumes that you have received your cache from netman.api.
---     -- If that confuses you, please see netman.api.register_provider for details
---     -- or :help netman.api.providers
---     local cache = cache
---     local host = SSH:new('ssh://user@host')
---     host:archive('/tmp', '/tmp/', {'tar.gz'}, cache)
function SSH:archive(locations, archive_dir, compatible_scheme_list, provider_cache, opts)
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
            if not location:match(SSH.CONSTANTS.SSH_PROTO_GLOB) then
                -- A little bit of uri coalescing
                ---@diagnostic disable-next-line: cast-local-type
                location = self:_create_uri(location)
            end
            location = URI:new(location)
        end
        assert(location.__type and location.__type == 'netman_uri',
            string.format("%s is not a valid Netman URI", location))
        table.insert(converted_locations, location)
    end
    locations = converted_locations
    local archive_name = opts.output_file_name or string.format("%s.%s", string_generator(10), selected_compression)
    local compress_command = compression_function(locations, provider_cache)
    local archive_path = string.format("%s/%s", archive_dir, archive_name)
    local finish_callback = function(output)
        logger.trace(output)
        if output.exit_code ~= 0 then
            local _error = "Received non-0 exit code when trying to archive locations"
            logger.warn(_error, { locations = locations, error = output.stderr, exit_code = output.exit_code })
            return_details = { error = _error, success = false }
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
        [command_flags.STDOUT_PIPE_LIMIT] = 0,
        [command_flags.ASYNC] = opts.async and true or false,
        [command_flags.STDOUT_FILE] = string.format("%s/%s", archive_dir, archive_name)
    }
    -- TODO
    -- if opts.remote_dump then
    --     -- This probably doesn't work
    --     compress_command = string.format("mkdir -p %s && %s > %s/%s", archive_dir, compress_command, archive_dir,
    --         archive_name)
    --     archive_path = string.format("ssh://%s///%s/%s", self.host, archive_dir, archive_name)
    -- else
    -- end
    local run_details = self:run_command(compress_command, command_options)
    if not opts.async then return return_details else return run_details end
end

--- Extracts the provided archive into the target location in the host
--- @param archive string
---     The location of the archive to extract
--- @param target_dir URI
---     The location to extract to
--- @param scheme string
---     The scheme the archive is compressed with
--- @param opts table | nil
---     Default: {}
---     A list of options to be used when extracting. Available key/values are
---         - async: boolean
---             If provided, we will run the extraction asynchronously. It is recommended
---             that finish_callback is used with this
---         - ignore_errors: boolean
---             If provided, we will not output any errors we get
---         - cleanup: boolean
---             Indicates that we need to delete the archive after successful extraction
---         - finish_callback: function
---             A function to call when the get is complete. Note, this is an asychronous function
---             so if you want to get output from the get, you will want to provide this
--- @return table
---     Returns a table that contains the following key/value pairs
---     - success: boolean
---         A true/false to indicate if the extraction was a success
---     - error: string | nil
---         The string error that was encountered during extraction. May not be present
--- @example
---     -- This example assumes that you have received your cache from netman.api.
---     -- If that confuses you, please see netman.api.register_provider for details
---     -- or :help netman.api.providers
---     local cache = cache
---     -- Additionally, it assumes that `/tmp/some.tar.gz` exists on the local machine
---     local host = SSH:new('user@host')
---     host:extract('/tmp/some.tar.gz', '/tmp/', 'tar.gz', cache)
-- -     -- TODO: Add an example of how to do an extract with a Pipe...
function SSH:extract(archive, target_dir, scheme, opts)
    opts = opts or {}
    local return_details = {}
    local run_details = {}
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
        if not target_dir:match(SSH.CONSTANTS.SSH_PROTO_GLOB) then
            -- A little bit of uri coalescing
            ---@diagnostic disable-next-line: cast-local-type
            target_dir = self:_create_uri(target_dir)
        end
        target_dir = URI:new(target_dir)
    end
    assert(target_dir.__type and target_dir.__type == 'netman_uri',
        string.format("%s is not a valid netman uri", target_dir))
    local finish_callback = function(command_output)
        logger.trace(command_output)
        if command_output.exit_code ~= 0 then
            local _error = string.format("Unable to extract %s", archive)
            logger.warn(_error, { exit_code = command_output.exit_code, error = command_output.stderr })
            return_details = { error = _error, success = false }
            if opts.finish_callback then opts.finish_callback(return_details) end
        end
        if opts.cleanup then
            ---@diagnostic disable-next-line: param-type-mismatch, missing-parameter
            self:rm(archive)
        end
        return_details = { success = true }
        if opts.finish_callback then opts.finish_callback(return_details) end
    end
    local command_options = {
        [command_flags.STDERR_JOIN] = '',
        [command_flags.ASYNC] = true,
        -- We don't want STDOUT for this
        [command_flags.STDOUT_PIPE_LIMIT] = 0,
        [command_flags.EXIT_CALLBACK] = finish_callback
    }
    local handle = self:run_command(extraction_function(target_dir, archive), command_options)
    if not opts.async then
        return handle
    end
    return run_details
end

--- Copies location(s) to another location in the ssh
--- @param locations table
---     The a table of string locations to move. Can be a files or directories
--- @param target_location string
---     The location to move to. Can be a file or directory
--- @param opts table | nil
---     Default: {}
---     If provided, a table of options that can be used to modify how copy works
---     Valid Options
---     - ignore_errors:
---         If provided, we will not report any errors received while attempting copy
--- @return table
---     Returns a table that contains the following key/value pairs
---     - success: boolean
---         A true/false on if we successfully executed the copy
---     - error: string | nil
---         Any errors that occured during copy. Note, if opts.ignore_errors was provided, even if we get an error
---         it will not be returned. Ye be warned
--- @example
---     local host = SSH:new('someuser@somehost')
---     -- Copies /tmp/testfile.txt into /opt
---     host:cp('/tmp/testfile.txt', '/opt')
---     -- Or to copy multiple locations
---     host:cp({'/tmp/testfile.txt', '/tmp/new_dir/'}, '/opt')
function SSH:cp(locations, target_location, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    if target_location.__type and target_location.__type == 'netman_uri' then target_location = target_location:
            to_string()
    end
    local cp_command = { 'cp', '-a' }
    local __ = {}
    for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then
            location = location:to_string()
        end
        table.insert(__, location)
        table.insert(cp_command, location)
    end
    locations = __
    table.insert(cp_command, target_location)
    cp_command = table.concat(cp_command, ' ')
    local command_options = {
        [command_flags.STDERR_JOIN] = ''
    }
    local output = self:run_command(cp_command, command_options)
    if output.exit_code ~= 0 and not opts.ignore_errors then
        local message = string.format("Unable to move %s to %s", table.concat(locations, ' '), target_location)
        return { success = false, error = message }
    end
    return { success = true }
end

--- Moves a location to another location in the ssh
--- @param locations table
---     The a table of string locations to move. Can be a files or directories
--- @param target_location string
---     The location to move to. Can be a file or directory
--- @param opts table | nil
---     Default: {}
---     If provided, a table of options that can be used to modify how mv works
---     Valid Options
---     - ignore_errors: boolean
---         If provided, we will not report any errors received while attempting move
--- @return table
---     Returns a table that contains the following key/value pairs
---     - success: boolean
---         A true/false on if we successfully executed the move
---     - error: string | nil
---         Any errors that occured during move. Note, if opts.ignore_errors was provided, even if we get an error
---         it will not be returned. Ye be warned
--- @example
---     local host = SSH:new('someuser@somehost')
---     host:mv('/tmp/testfile.txt', '/tmp/testfile2.txt')
function SSH:mv(locations, target_location, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    if target_location.__type and target_location.__type == 'netman_uri' then target_location = target_location:
            to_string()
    end
    local mv_command = { 'mv' }
    local __ = {}
    for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then
            location = location:to_string()
        end
        table.insert(__, location)
        table.insert(mv_command, location)
    end
    locations = __
    if #locations > 1 then
        table.insert(mv_comand, '-t')
    end
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

--- Touches a file in the host
--- @param locations table
---     A table of filesystem locations (as strings) touch
--- @param opts table | nil
---     Default: {}
---     A list of key/value pair options that can be used to tailor how mkdir does "things". Valid key/value pairs are
---     - async: boolean
---         If provided, tells touch to run asynchronously. This affects the output of this function as we now will return a handle to the job instead of tahe data
---     - finish_callback: function
---         If provided, we will call this function with the output of touch. Note, we do _not_ stream the results. Highly recommended if you also provide `opts.async`
---     - ignore_errors: boolean
---         - If provided, we will not complain one bit when things explode :)
--- @return table
---     Returns a table that contains the following key/value pairs
---     - success: boolean
---         A true/false on if we successfully created the directory
---     - error: string | nil
---         Any errors that occured during creation of the directory. Note, if opts.ignore_errors was provided, even if we get an error
---         it will not be returned. Ye be warned
--- @example
---     local host = SSH:new('someuser@somehost')
---     host:touch('/tmp/testfile.txt')
---     -- Or async
---     host:touch('/tmp/testfile.txt', {
---         async = true,
---         finish_callback = function(output)
---             print(output)
---         end
---     })
function SSH:touch(locations, opts)
    opts = opts or {}
    local return_data = nil
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    local touch_command = { "touch" }
    local __ = {}
    for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then location = location:to_string() end
        table.insert(touch_command, location)
        table.insert(__, location)
    end
    locations = __
    local finish_callback = function(output)
        local callback = opts.finish_callback
        if output.exit_code ~= 0 and not opts.ignore_errors then
            local _error = string.format("Unable to touch %s", table.concat(locations, ' '))
            logger.warn(_error, { exit_code = output.exit_code, error = output.stderr })
            return_data = { success = false, error = _error }
            if callback then callback(return_data) end
            return
        end
        return_data = { success = true }
        if callback then callback(return_data) end
    end
    local output = self:run_command(touch_command, {
        no_shell = true,
        [command_flags.EXIT_CALLBACK] = finish_callback,
        [command_flags.ASYNC] = opts.async
    })
    if opts.async then return output end
    return return_data
end

--- Creates a directory in the host
--- @param locations table
---     A table of filesystem locations (as strings) create
--- @param opts table | nil
---     Default: {}
---     A list of key/value pair options that can be used to tailor how mkdir does "things". Valid key/value pairs are
---     - async: boolean
---         If provided, tells stat to run asynchronously. This affects the output of this function as we now will return a handle to the job instead of the data
---     - finish_callback: function
---         If provided, we will call this function with the output of mkdir. Note, we do _not_ stream the results.
---     - ignore_errors: boolean
---         - If provided, we will not complain one bit when things explode :)
--- @return table
---     Returns a table that contains the following key/value pairs
---     - success: boolean
---         A true/false on if we successfully created the directory
---     - error: string | nil
---         Any errors that occured during creation of the directory. Note, if opts.ignore_errors was provided, even if we get an error
--- @example
---     local host = SSH:new('someuser@somehost')
---     host:mkdir('/tmp/testdir1')
---     -- Or async
---     host:mkdir('/tmp/testdir1', {
---         async = true,
---         finish_callback = function(output)
---             print(output)
---         end
---     })
function SSH:mkdir(locations, opts)
    opts = opts or {}
    local return_data = nil
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    -- It may be worth having this do something like
    -- test -d location || mkdir -p location
    -- instead, though I don't know that that is preferrable...?
    local mkdir_command = { "mkdir", "-p" }
    local __ = {}
    for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then location = location:to_string() end
        table.insert(mkdir_command, location)
        table.insert(__, location)
    end
    locations = __
    local finish_callback = function(output)
        logger.trace(output)
        local callback = opts.finish_callback
        if output.exit_code ~= 0 and not opts.ignore_errors then
            local _error = string.format("Unable to make %s", table.concat(locations, ' '))
            logger.warn(_error, { exit_code = output.exit_code, error = output.stderr })
            return_data = { success = false, error = _error }
            if callback then callback(return_data) end
            return
        end
        return_data = { success = true }
        if callback then callback(return_data) end
    end
    local output = self:run_command(mkdir_command, {
        no_shell = true,
        [command_flags.EXIT_CALLBACK] = finish_callback,
        [command_flags.ASYNC] = opts.async
    })
    if opts.async then return output end
    return return_data
end

--- @param locations table
---     A table of netman uris to remove
--- @param opts table | nil
---     Default: {}
---     A list of key/value pair options that can be used to tailor how rm does "things". Valid key/value pairs are
---     - force: boolean
---         - If provided, we will try to force the removal of the targets
---     - ignore_errors: boolean
---         - If provided, we will not complain one bit when things explode :)
---     - async: boolean
---         - If provided, we will run the rm command asynchronously. You will get a shell handle back instead of the
---         - usual response.
---     - finish_callback: function
---         - If provided, we will call this with the output of the removal instead. Note, it is recommended to use
---         - this with opts.async or you will not get any response from the job!
--- @return table
---     Returns a table that contains the following key/value pairs
---     - success: boolean
---         A true/false on if we successfully created the directory
---     - error: string | nil
---         Any errors that occured during creation of the directory. Note, if opts.ignore_errors was provided, even if we get an error
---         it will not be returned. Ye be warned
--- @example
---     local host = SSH:new('someuser@somehost')
---     host:rm('/tmp/somedir')
---     -- You can also provide the `force` flag to force removal of a directory
---     host:rm('/tmp/somedir', {force=true})
---     -- You can also also provide the `ignore_errors` flag if you don't care if this
---     -- works or not
---     host:rm('/tmp/somedir', {ignore_errors=true})
---     -- You can also do the removal asynchronously
---     host:rm('/tmp/somdir', {
---         async = true,
---         finish_callback = function(output) print("RM Output", vim.inspect(output) end)
---     })
function SSH:rm(locations, opts)
    opts = opts or {}
    local return_data = nil
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    local rm_command = { 'rm', '-r' }
    if opts.force then table.insert(rm_command, '-f') end
    local __ = {}
    for _, location in ipairs(locations) do
        if type(location) == 'string' then
            if not location:match(SSH.CONSTANTS.SSH_PROTO_GLOB) then
                -- A little bit of uri coalescing
                ---@diagnostic disable-next-line: cast-local-type
                location = self:_create_uri(location)
            end
            location = URI:new(location)
        end
        assert(location.__type and location.__type == 'netman_uri',
            string.format("%s is not a valid netman uri", location))
        table.insert(rm_command, location:to_string())
        table.insert(__, location:to_string())
    end
    locations = __
    local finish_callback = function(output)
        local callback = opts.finish_callback
        if output.exit_code ~= 0 and not opts.ignore_errors then
            local _error = string.format("Unable to delete %s", table.concat(locations, ' '))
            logger.warn(_error, { exit_code = output.exit_code, error = output.stderr })
            return_data = { success = false, error = _error }
            if callback then callback(return_data) end
            return
        end
        return_data = { success = true }
        if callback then callback(return_data) end
    end
    local output = self:run_command(rm_command, {
        no_shell = true,
        [command_flags.EXIT_CALLBACK] = finish_callback,
        [command_flags.ASYNC] = opts.async
    })
    if opts.async then return output end
    return return_data
end

--- Runs find within the host
--- @param location string or URI
---     The location to find from
--- @param search_param string
---     The string to search for
--- @param opts table | nil
---     - Default: {
---         pattern_type = 'iname',
---         follow_symlinks = true,
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
---     - multi_item_exec: boolean
---         - Default: False
---         - If provided, tells us that you want find's exec to run individual shell instances
---         for each match. For more details on this, look at `man find`. Specifically `-exec`
---         - By not providing this, we will default to using finds `;` option which means
---         that exec will execute a new "command" for every match. If you can, you should consider
---         setting this to true as you will see great performance increases
---     - exec: string or function | nil
---         - If provided, will be used as the `exec` flag with find.
---         Note: the `string` form of this needs to be a find compliant shell string. @see man find for details
---         Alternatively, you can provide a function that will be called with every match that find gets. Note, this will be significantly slower
---         than simply providing a shell string command, so if performance is your goal, use `string`
--- @return table
---     Returns the return value of @see SSH:run_command
function SSH:find(location, opts)
    local default_opts = {
        follow_symlinks = true,
        min_depth = 1,
        filesystems = true
    }
    opts = opts or {}
    -- Ensuring that sensible defaults are set in the event that options are provided and are missing defaults
    for key, value in pairs(default_opts) do
        if opts[key] == nil then opts[key] = value end
    end
    if location.__type and location.__type == 'netman_uri' then location = location:to_string() end
    local find_command = { 'find', location }
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
            error(string.format("Invalid Find Pattern Type: %s. See :h netman.providers.ssh.find for details",
                opts.pattern_type))
        end
        table.insert(find_command, string.format('"%s"', opts.search_param))
    end
    local op = ";"
    if opts.multi_item_exec then op = "+" end
    local command_options = {
        [command_flags.STDERR_JOIN] = '',
        [command_flags.ASYNC] = opts.async,
        [command_flags.STDOUT_CALLBACK] = opts.stdout_callback,
        [command_flags.STDERR_CALLBACK] = opts.stderr_callback,
        [command_flags.EXIT_CALLBACK] = opts.exit_callback
    }
    if opts.exec then
        local _ = type(opts.exec)
        assert(_ == 'string' or _== 'function', "Invalid Exec provided for SSH:find. Exec should be a shell command (string) or function!")
        if type(opts.exec) == 'string' then
            table.insert(find_command, "-exec")
            table.insert(find_command, opts.exec .. " {} \\" .. op)
        else
            command_options[command_flags.STDOUT_CALLBACK] = opts.exec
        end
    end
    -- Note, this will return a handle to the running command
    -- if opts.async is provided
    local output = self:run_command(table.concat(find_command, ' '), command_options)
    if opts.async then return output end
    if output.exit_code ~= 0 then
        return {
            error = output.stderr,
            output = output.stdout
        }
    end
    return output.stdout
end

function SSH:grep(uri, param, opts)
    error("Grep is not implemented on ssh yet!")
end

--- Attempts to get the user's home directory
--- @param user string | nil
---     Default: current logged in user
---     The user to get the home directory for.
--- @return uri string | nil
---     The uri that can be resolved to the user's home directory. Note, can also be nil
---     if the directory cannot be resolved/found
function SSH:_get_user_home(user)
    -- Since ssh is usually "over" the network, its probably worth having this do multiple commands
    -- at once
    --
    -- Lets try the following commands
    user = user or '$USER'
    local command = string.format('echo "{\\\"FILE_READ\\\":\\\"$(cat /etc/passwd | grep -E "%s.*")\\\",\\\"COMMAND_OUTPUT\\\":\\\"${HOME}\\\"}"', user)
    local output = self:run_command(command)
    if not output.stdout then
        -- We got literally nothing, so thats not great.
        -- return nil I guess?
        return nil
    end
    if output.exit_code ~= 0 then
        -- Logger the exit code, and still attempt to read the output, we might be able to establish what we need
        logger.warn("Received non-0 exit code", {stdout = output.stdout, stderr = output.stderr})
    end
    local success, details = pcall(JSON.decode, JSON, output.stdout)
    if success ~= true then
        logger.warn("Unable to parse home directory of user!", {error = details})
        return nil
    end
    if details.COMMAND_OUTPUT then
        return details.COMMAND_OUTPUT
    end
    logger.warn("Unable to resolve home directory of user!")
    return nil
    -- TODO: Mike, we need to figure out how to parse this better
    -- if details.FILE_READ then

end

--- Uploads a file to the host, placing it in the provided location
--- @param file string
---     The string file location on the host
--- @param location URI
---     The location to put the file
--- @param opts table | nil
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
---     local host = SSH:new('someuser@somehost')
---     host:put('/tmp/ubuntu.tar.gz', '/tmp/ubuntu')
function SSH:put(file, location, opts)
    opts = opts or {}
    local return_details = {}
    assert(vim.loop.fs_stat(file), string.format("Unable to locate %s", file))
    if type(location) == 'string' then
        if not location:match(SSH.CONSTANTS.SSH_PROTO_GLOB) then
            -- A little bit of uri coalescing
            ---@diagnostic disable-next-line: cast-local-type
            location = self:_create_uri(location)
        end
        location = URI:new(location)
    end
    assert(location.__type and location.__type == 'netman_uri', string.format("%s is not a valid netman URI", location))
    local file_name = location:to_string()
    if location.type ~= api_flags.ATTRIBUTES.DIRECTORY then
        local _error = string.format("Unable to verify that %s is a directory, you might see errors!",
            location:to_string())
        local status, ___ = pcall(SSH.stat, self, location, { SSH.CONSTANTS.STAT_FLAGS.TYPE })
        -- Running this in protected mode because `location` may not exist. If it doesn't we will get an error,
        -- we don't actually care about the error we get, we are going to assume that the location doesn't exist
        -- if we get an error. Thus, error == gud
        if status == true then
            local _stat = ___.data
            if _stat.TYPE ~= 'directory' then
                logger.info(_error)
                file_name = location:to_string()
                location = location:parent()
            end
        end
    end
    local mkdir_status = self:mkdir(location)
    if not mkdir_status or not mkdir_status.success then
        return_details = { success = false, error = mkdir_status.error or SSH.CONSTANTS.MKDIR_UNKNOWN_ERROR }
        if opts.finish_callback then
            opts.finish_callback(return_details)
            return
        end
        return return_details
    end
    if opts.new_file_name then
        file_name = string.format("%s/%s", location:to_string(), opts.new_file_name)
    end
    local finish_callback = function(command_output)
        logger.trace(command_output)

        if command_output.exit_code ~= 0 and not opts.ignore_errors then
            local _error = string.format("Unable to upload %s", file)
            logger.warn(_error, { exit_code = command_output.exit_code, error = command_output.stderr })
            return_details = { error = _error, success = false }
            if opts.finish_callback then opts.finish_callback(return_details) end
            return
        end
        return_details = { success = true }
        if opts.finish_callback then opts.finish_callback(return_details) end
    end
    local copy_command = { 'scp' }
    for _, __ in ipairs(self._get_command) do
        table.insert(copy_command, __)
    end
    local destination = copy_command[#copy_command]
    table.remove(copy_command, #copy_command)
    table.insert(copy_command, file)
    table.insert(copy_command, string.format("%s:%s", destination, file_name))
    local command_options = {
        [command_flags.STDOUT_JOIN] = '',
        [command_flags.STDERR_JOIN] = '',
        [command_flags.EXIT_CALLBACK] = finish_callback
    }
    if opts.async then
        command_options[command_flags.ASYNC] = true
    end
    ---@diagnostic disable-next-line: missing-parameter
    local run_details = shell:new(copy_command, command_options):run()
    if not opts.async then return return_details else return run_details end
end

--- Retrieves a file from the host and saves it in the output directory
--- NOTE: This can only be used to retrieve files. Directories must be archived with @see SSH:archive
--- @param location URI
---     A netman URI of the location to download
--- @param output_dir string
---     The string filesystem path to download to
--- @param opts table | nil
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
---         - A function to call when the get is complete. Note, this is basically required if you provide
---         `async = true` in the options. If you want to get output from the get, you will want to provide this
---     - new_file_name: string
---         - If provided, sets the downloaded file name to this. By default the file will maintain its
---         current filename
--- @return table
---     The return contents here varies depending on if `:get` is called asynchronously or not.
---     If it is called with `opts.finish_callback` defined, you will get the following a shell handled returned.
---     for details on this, please see netman.tools.shell.new_async_handler
---
---     If opts.finish_callback is not provided, you will receive the below table, and if it is provided, this
---     table will be sent to the aforementioned callback associated with `opts.finish_callback`
---     {
---         - success: boolean
---             - A true/false indicating if the get was successful
---         - error: {
---             - message: string
---             - A string of errors that occured during the get. Note, this table will only be provided if there
---             - were errors encountered
---           }
---         - data: {
---             - file: string
---               - String representation of the local absolute path of the downloaded file
---           }
---     }
--- @example
---     local host = SSH:new('someuser@somehost')
---     host:get('/tmp/ubuntu.tar.gz', '/tmp/')
---     -- OR
---     local callback = function(result)
---         if not result.success then
---             -- Handle failure to download?
---             print(string.format("Unable to download /tmp/ubuntu.tar.gz. Received Error: %s", result.error.message))
---             return
---         end
---         print(string.format("Downloaded /tmp/ubuntu.tar.gz to %s", result.data.file))
---     end
---     host:get('/tmp/ubuntu.tar.gz', '/tmp/', {async = true, finish_callback = callback}) -- This will run the get command asynchronously
function SSH:get(location, output_dir, opts)
    opts = opts or {}
    local return_details = {}
    assert(vim.loop.fs_stat(output_dir), string.format("Unable to locate %s. Is it a directory?", output_dir))
    if type(location) == 'string' then
        if not location:match(SSH.CONSTANTS.SSH_PROTO_GLOB) then
            -- A little bit of uri coalescing
            ---@diagnostic disable-next-line: cast-local-type
            location = self:_create_uri(location)
        end
        location = URI:new(location)
    end
    assert(location.__type and location.__type == 'netman_uri', string.format("%s is not a valid netman URI", location))
    local file_name = opts.new_file_name or location.path[#location.path]
    local finish_callback = function(command_output)
        logger.trace(command_output)
        if command_output.exit_code ~= 0 and not opts.ignore_errors then
            local _error = string.format("Unable to download %s", location:to_string())
            logger.warn(_error, { exit_code = command_output.exit_code, error = command_output.stderr })
            return_details = { error = command_output.stderr, success = false }
            if opts.finish_callback then opts.finish_callback(return_details) end
            return
        end
        return_details = {
            success = true,
            data = {
                file = string.format("%s%s", output_dir, file_name)
            }
        }
        if opts.finish_callback then opts.finish_callback(return_details) end
    end
    local copy_command = nil
    local command_options = {
        [command_flags.STDERR_JOIN] = '',
        [command_flags.EXIT_CALLBACK] = finish_callback,
        [command_flags.ASYNC] = opts.async and true or false
    }
    if opts.force then
        -- Shenanigans activate!
        command_options[command_flags.STDOUT_FILE] = string.format('%s/%s', output_dir, file_name)
        copy_command = {}
        for _, __ in ipairs(self.console_command) do
            table.insert(copy_command, __)
        end
        table.insert(copy_command, '/bin/sh')
        table.insert(copy_command, '-c')
        table.insert(copy_command, string.format('cat %s', location:to_string()))
    else
        copy_command = { 'scp' }
        for _, __ in ipairs(self._get_command) do
            table.insert(copy_command, __)
        end
        copy_command[#copy_command] = string.format("%s:%s", copy_command[#copy_command], location:to_string())
        table.insert(copy_command, string.format("%s%s", output_dir, file_name))
        command_options[command_flags.STDOUT_JOIN] = ''
    end
    ---@diagnostic disable-next-line: missing-parameter
    local run_details = shell:new(copy_command, command_options):run()
    if not opts.async then return return_details else return run_details end
end

--- Takes a table of filesystem locations and returns the stat of them
--- @param locations table
---     - A table of filesystem locations
--- @param target_flags table | nil
---     Default: Values from @see Container.CONSTANTS.STAT_FLAGS
---     - If provided, will return a table with only these keys and their respective values
---     - NOTE: You will _always_ get `NAME` back, even if you explicitly tell us not to return
---     it. We use it to order the stat entries on return, so deal with it
--- @param opts table | nil
---     Default: {}
---     - If provided, the following key/value pairs are acceptable
---         - async: boolean
---             - If provided, tells stat to run asynchronously. This affects the output of this function
---             as we now will return a handle to the job instead of the data
---         - finish_callback: function
---             - If provided, we will call this function with the output of stat. Note, we do _not_ stream
---             the results, instead just calling this with the same big table as we would return synchronously
--- @return table
---     The output of this function depends on if `opts.async` is defined or not.
---     If it is, this function will return 
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
--- @example
---     local host = SSH:new('someuser@somehost')
---     print(vim.inspect(host:stat('/tmp')))
function SSH:stat(locations, target_flags, opts)
    local remote_locations = {}
    --TODO: (Mike) Consider caching this for a short amount of time????
    opts = opts or {}
    -- Coerce into a table for iteration
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    local return_details = nil
    local finish_callback = function(output)
        logger.trace(output)
        local callback = opts.finish_callback
        if output.exit_code ~= 0 then
            local r_locations = table.concat(remote_locations, ', ')
            local _error = "Received non-0 exit code while trying to stat"
            if r_locations:len() > 0 then
                _error = _error .. ' ' .. r_locations
            end
            local suberror = nil
            if
                output.stderr:match('No route to host')
                or output.stderr:match('Could not resolve hostname')
            then
                suberror = string.format("Unable to connect to ssh host %s", self.host)
            elseif output.stderr:match('[pP]assword') then
                suberror = "Invalid/Missing Password"
            elseif output.stderr:match('No such file or directory') then
                suberror = "No such file or directory"
            end
            if suberror then _error = string.format("%s: %s", _error, suberror) end
            logger.warn(_error, { locations = locations, error = output.stderr, exit_code = output.exit_code, stdout = output.stdout})
            return_details = { error = _error, success = false}
            if callback then callback(return_details) end
            return
        end
        local data = self:_stat_parse(output.stdout, target_flags)
        if not data then
            local _error = "Unable to process stat output"
            logger.warn(_error, { locations = locations, error = output.stderr, exit_code = output.exit_code, output=output.stdout })
            return_details = { error = _error, success = false }
            if callback then callback(return_details) end
            return
        end
        return_details = {
            success = true,
            data = data
        }
        if callback then callback(return_details) end
    end
    local stat_flags = {
        '-L',
        '-c',
        'MODE=%f,BLOCKS=%b,BLKSIZE=%B,MTIME_SEC=%X,USER=%U,GROUP=%G,INODE=%i,PERMISSIONS=%a,SIZE=%s,TYPE=%F,NAME=%n'
    }
    local stat_command = { 'stat' }
    for _, flag in ipairs(stat_flags) do
        table.insert(stat_command, flag)
    end
    local __ = {}
    for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then
            table.insert(remote_locations, location:to_string('remote'))
            location = location:to_string()
        end
        table.insert(__, location)
        table.insert(stat_command, location)
    end
    locations = __
    local command_opts = {
        [command_flags.STDERR_JOIN] = '',
        [command_flags.EXIT_CALLBACK] = finish_callback,
        [command_flags.ASYNC] = opts.async
    }
    local handle = self:run_command(stat_command, command_opts)
    -- If async was not specified then this will block until the above `finish_callback` is complete
    -- which will subsequently set return_details
    if opts.async then return handle end
    return return_details
    -- return self:_stat_parse(stat_details.stdout, target_flags)
end

function SSH:_stat_parse(stat_output, target_flags)
    if not target_flags then
        target_flags = {}
        for key, value in pairs(SSH.CONSTANTS.STAT_FLAGS) do
            target_flags[key] = value
        end
    else
        local __ = {}
        for _, key in pairs(target_flags) do
            __[key:upper()] = SSH.CONSTANTS.STAT_FLAGS[key]
        end
        if not __[SSH.CONSTANTS.STAT_FLAGS['NAME']] then __[SSH.CONSTANTS.STAT_FLAGS['NAME']] = SSH.CONSTANTS.STAT_FLAGS
                .NAME
        end
        target_flags = __
    end
    if type(stat_output) == 'string' then stat_output = { stat_output } end
    local stat = {}
    for _, line in ipairs(stat_output) do
        line = line:gsub('(\\0)', '')
        local item = {}
        local _type = nil
        for _, pattern in ipairs(find_pattern_globs) do
            local key, is_number, value = line:match(pattern)
            key = key:gsub('(^\n)', '')
            line = line:gsub(pattern, '')
            if is_number:len() > 0 then
                value = tonumber(value)
            end
            if target_flags[key:upper()] then
                item[key:upper()] = value
            end
        end
        _type = item.TYPE:upper()
        if target_flags[SSH.CONSTANTS.STAT_FLAGS.URI] then
            item[SSH.CONSTANTS.STAT_FLAGS.URI] = self:_create_uri(item.NAME)
            if _type:upper() == 'DIRECTORY' and item.NAME:sub(-1, -1) ~= '/' then
                item[SSH.CONSTANTS.STAT_FLAGS.URI] = item[SSH.CONSTANTS.STAT_FLAGS.URI] .. '/'
            end
        end
        if target_flags[SSH.CONSTANTS.STAT_FLAGS.TYPE] then
            if _type:upper() == 'DIRECTORY' then
                item['FIELD_TYPE'] = metadata_options.LINK
            elseif _type:upper() == 'REGULAR FILE' or _type:upper() == 'REGULAR EMPTY FILE' then
                item['FIELD_TYPE'] = metadata_options.DESTINATION
            end
        end
        item['ABSOLUTE_PATH'] = item.NAME
        local name = ''
        local cur_path = ''
        local path = {}
        for _ in item.NAME:gmatch('[^/]+') do
            name = _
            cur_path = cur_path .. "/" .. _
            table.insert(path, {
                uri = self:_create_uri(cur_path .. '/'),
                name = _
            })
        end
        if not name or name:len() == 0 then
            -- Little catch to deal with if the file is literally named '/'
            name = item.NAME
        end
        path[#path] = {uri = item[SSH.CONSTANTS.STAT_FLAGS.URI], name = name}
        local absolute_path = item.NAME
        item[SSH.CONSTANTS.STAT_FLAGS.ABSOLUTE_PATH] = path
        item.NAME = name
        stat[absolute_path] = item
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
--- @param opts table | nil
---     Default: {}
---     If provided, a table that can alter how stat_mod operates. Valid Key Value Pairs are
---     - remove_mod: boolean
---         - If provided, will inverse and _remove_ the mods as opposed to adding them
---           This is how you would set `chmod u-r` to remove read access from a user (for example)
--- @return boolean
---     Returns a true/false boolean on if the change was successful or not
--- @example
---     local host = SSH:new('someuser@somehost')
---     -- This is equivalent to chmod ug+r /tmp/ubuntu.tar.gz
---     host:stat_mod('/tmp/ubuntu.tar.gz', {'user', 'group'}, {'read'})
---     -- This is equivalent to chmod ug-w /tmp/ubuntu.tar.gz
---     host:stat_mod('/tmp/ubuntu.tar.gz', {'user', 'group'}, {'write'}, {remove_mod = true})
function SSH:stat_mod(locations, targets, permission_mods, opts)
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
        logger.warn("Received Error trying to modify permissions")
        return false
    end
    return true
end

--- Changes the owner or group owner of a location
--- @param locations table
---     A table of filesystem locations
--- @param ownership table
---     A 2D table that can contain any of the following keys
---     - user
---     - group
---     The value associated with each key should be the string for that key. EG { user = 'root', group = 'nogroup'}
--- @param opts table | nil
---     - Default: {}
---     If provided, a table that can alter how own_mod operates. Valid Key Value Paris are
---     - ignore_errors: boolean
---         - If provided, we will not report any errors that occur while trying to change the ownership
---          of the locations provided
--- @example
---     local host = SSH:new('ubuntu')
---     -- This will modify the owner and group of /tmp/ to be root
---     host:own_mod('/tmp/', { user = 'root', group = 'root' })
---     -- This will modify the group of /tmp/somedir and /tmp/somedir2 to be nogroup
---     host:own_mod({'/tmp/somedir', '/tmp/somedir2'}, { group = 'nogroup' })
function SSH:own_mod(locations, ownership, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    assert(ownership, "Invalid ownership provided")
    local command = {'chown'}
    if ownership.user then
        if ownership.group then
            table.insert(command, string.format("%s:%s", ownership.user, ownership.group))
        else
            table.insert(command, ownership.user)
        end
    elseif ownership.group then
        command = { 'chgrp', ownership.group }
    end
    if #command <= 1 then
        -- We didn't find any matches to apply to the command!
        logger.warn("Invalid ownership provided", {locations = locations, ownership = ownership})
        return false
    end
    for _, location in ipairs(locations) do
        table.insert(command, location)
    end
    local output = self:run_command(command)
    if output.exit_code ~= 0 then
        logger.warn("Received Error trying to modify ownership")
        return false
    end
    return true
end

--- URI Object functions
--------------------------------------
function URI:new(uri, cache)
    -- TODO: Maybe include some what to indicate the identity file in the URI??????
    -- If a cache is provided and we are in it, return us!
    if cache and cache:get_item(uri) then return cache:get_item(uri) end

    local _uri = {}
    local protocol = uri:match('^([scftph]+)://')
    --- Make sure we get _some_ protocol match
    assert(protocol, string.format("Invalid Format: %s", uri))
    local match = false
    for _, prot in ipairs(M.protocol_patterns) do
        match = prot == protocol:lower()
        if match then break end
    end
    -- Make sure we get a valid protocol
    assert(match, string.format("Invalid Format: %s", uri))

    _uri.uri = uri
    _uri.protocol = protocol
    -- We don't support keys yet
    _uri.key = ''
    uri = uri:gsub(string.format('%s://', _uri.protocol), '')
    -- Host _might_ include a username, so we need to split those apart if they exist
    _uri.user = uri:match('^([^@]+)@') or ''
    if _uri.user:len() > 0 then
        uri = uri:gsub(string.format("%s@", _uri.user), '')
    end
    _uri.host = uri:match('^([^:^/]+)')
    assert(_uri.host, string.format("Invalid URI: %s Unable to parse host", _uri.uri))
    uri = uri:gsub('^([^/^:]+)', '')
    _uri.port = uri:match('^:([0-9]+)') or ''
    if _uri.port:len() > 0 then
        uri = uri:gsub(string.format(":%s", _uri.port), '')
    end
    -- Put together the auth URI
    local auth_uri = {}
    if _uri.protocol == 'ssh' then
        -- Create SSH command
        table.insert(auth_uri, 'ssh')
        local _ = _uri.host
        if _uri.user:len() > 0 then _ = string.format("%s@%s", _uri.user, _uri.host) end
        table.insert(auth_uri, _)
        if _uri.port:len() > 0 then table.insert(auth_uri, string.format("-p %s", _uri.port)) end
    else
        -- You will notice that we don't have a section to create the SFTP command.
        -- This is because we are going to treat SFTP as SCP.
        -- Why you ask?
        -- There is no cli way to push files with SFTP. We can pull files, but to push
        -- requires some real garbage shell pipe manipulation and I have no interest
        -- in emulating that when SCP will work just fine. Get over it.
        -- Create SCP command
        table.insert(auth_uri, 'scp')
        local _ = _uri.host
        if _uri.user:len() > 0 then _ = string.format("%s@%s", _uri.user, _uri.host) end
        table.insert(auth_uri, _)
        if _uri.port:len() > 0 then table.insert(auth_uri, string.format("-P %s", _uri.port)) end
    end
    _uri.auth_uri = table.concat(auth_uri, ' ')
    assert(uri:match('^///') or uri:match('^/'),
        string.format("Invalid URI: %s Path start with either /// or /", _uri.uri))
    _uri.is_relative = true
    if uri:match('^///') then
        --- URI Path is absolute
        _uri.is_relative = false
    end
    --- Reduce the path down to a single `/` prepend
    uri = uri:gsub('^[/]+', '/')
    _uri.path = {}
    if _uri.is_relative then
        table.insert(_uri.path, '~')
    end
    for part in uri:gmatch('([^/]+)') do
        table.insert(_uri.path, part)
    end
    _uri.__path_as_string = string.format("%s", table.concat(_uri.path, "/"))
    if _uri.__path_as_string:sub(1, 1) ~= '/' and not (_uri.__path_as_string:match('^[$~]')) then
        _uri.__path_as_string = "/" .. _uri.__path_as_string
    end
    if uri:sub(-1, -1) == '/' then
        -- TODO: Consider using the container's `stat` method to check
        -- the metadata for the URI instead of string guessing?
        _uri.type = api_flags.ATTRIBUTES.DIRECTORY
        _uri.return_type = api_flags.READ_TYPE.EXPLORE
    else
        _uri.type = api_flags.ATTRIBUTES.FILE
        _uri.return_type = api_flags.READ_TYPE.FILE
        _uri.extension = _uri.path[#_uri.path]:match('%..*$') or ''
        _uri.unique_name = string.format("%s%s", string_generator(11), _uri.extension)
    end
    _uri.__type = 'netman_uri'
    setmetatable(_uri, self)
    self.__index = self
    if cache then cache:add_item(uri, _uri) end
    return _uri
end

function URI:to_string(style)
    style = style or 'local'
    if style == 'remote' then
        return self.uri
    end
    if style == 'local' then
        return self.__path_as_string
    end
    if style == 'auth' then
        return self.auth_uri
    end
    logger.warn(string.format("Invalid URI to_string style %s", style))
    return ''
end

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
    local path_sep = "///"
    if self.is_relative then
        path_sep = "/"
        if #_path == 0 then _path = { '$HOME' } end
    end
    if #_path == 0 then path_sep = '//' end
    return URI:new(
        string.format("ssh://%s%s%s", self.host, path_sep, table.concat(_path, '/') .. '/')
    )
end

--- Returns the various hosts that are currently available on the system
--- @param config Configuration
---     The Netman provided (provider managed) configuration
--- @return table
---     Returns a 1 dimensional table with the name of each host in it
function M.ui.get_hosts(config)
    local hosts_as_dict = config:get('hosts')
    local hosts = {}
    for host, _ in pairs(hosts_as_dict) do
        table.insert(hosts, host)
    end
    return hosts
end

--- Returns a list of details for a host
--- @param config Configuration
--- @param host string
--- @param provider_cache Cache
--- @return table
---     Returns a 1 dimensional table with the following key value pairs in it
---     - NAME
---     - URI
---     - STATE
---     - OS
---     - ENTRYPOINT
---         - Note, ENTRYPOINT may be a function as well, if getting the ENTRYPOINT is "painful" to get
function M.ui.get_host_details(config, host, provider_cache)
    -- TODO, its probably worth caching this stuff in our config instead of reaching out to each server to get the details
    local connection = SSH:new(host, provider_cache)
    local get_path = function()
        local home = connection.home
        local paths = nil
        if home then
            paths = {}
            local path = ''
            for _ in home:gmatch('[^/]+') do
                path = string.format('%s/%s', path, _)
                local uri_as_string = string.format('ssh://%s//%s/', host, path)
                if uri_as_string:sub(-1, -1) ~= '/' then uri_as_string = uri_as_string .. '/' end
                table.insert(paths, {uri = URI:new(uri_as_string).uri, name = _})
            end
        end
        return paths
    end
    local get_os = function()
        return connection.os
    end
    return {
        NAME = host,
        URI = string.format("ssh://%s///", host),
        OS = get_os,
        ENTRYPOINT = get_path
    }
end

function M.internal.prepare_config(config)
    logger.trace("Ensuring Provided SSH configuration has valid keys in it")
    if not config:get('hosts') then
        config:set('hosts', {})
        config:save()
    end
end

function M.internal.parse_user_sshconfig(config, ssh_config)
    local config_location = ssh_config or string.format("%s/.ssh/config", vim.loop.os_homedir())
    logger.infof("Parsing ssh configuration %s", config_location)
    local _config = io.open(config_location, 'r')
    if not _config then
        logger.warn(string.format("Unable to open user ssh config: %s", config_location))
        return
    end

    local hosts = config:get('hosts')

    local current_host = {}
    for line in _config:lines() do
        local host_line = line:match(HOST_MATCH_GLOB)
        if host_line then
            logger.trace(string.format("Processing SSH host: %s", host_line))
            if current_host.Host then
                local previous_hostname = current_host.Host
                current_host.Host = nil
                hosts[previous_hostname] = current_host
                logger.trace(string.format("Saving SSH Host: %s", previous_hostname), current_host)
            end
            local hostname = host_line:gsub('[%s]*$', '')
            current_host = { Host = hostname }
            -- We found a new host line
        end
        local key, value = line:match(HOST_ITEM_GLOB)
        if key then
            key = key:lower()
            if key == 'port' then
                value = tonumber(value)
            else
                value = value:lower()
            end
            current_host[key:lower()] = value
        end
    end
    config:save()
end

function M.internal.validate(uri, cache)
    assert(cache, string.format("No cache provided for read of %s", uri))
    ---@diagnostic disable-next-line: cast-local-type
    uri = M.internal.URI:new(uri, cache)

    local host = M.internal.SSH:new(uri, cache)
    return { uri = uri, host = host }
end

function M.internal.read_directory(uri, host, callback)
    logger.tracef("Reading %s as directory", uri:to_string("remote"))
    local find_cmd = 'stat -L -c \\|MODE=%f,BLOCKS=\\>%b,BLKSIZE=\\>%B,MTIME_SEC=\\>%X,USER=%U,GROUP=%G,INODE=\\>%i,PERMISSIONS=\\>%a,SIZE=\\>%s,TYPE=%F,NAME=%n\\|'

    local partial_output = {}
    local children = {}
    local incomplete = false
    local halted = false
    local stdout_callback = function(data, force)
        if halted then
            logger.info("Read directory processing has been forcefully halted, ignoring provided output")
            return
        end
        data = table.concat(partial_output, '') .. data
        partial_output = {}
        incomplete = false
        for line in data:gmatch('([^\n\r]+)') do
            if not force and (incomplete or line:match('^|$') or not line:match('|\n?$')) then
                -- The line is incomplete. Store it and wait for more?
                table.insert(partial_output, line)
                incomplete = true
                goto continue
            end
            -- Conditionally stripping bars off start and end
            if line:sub(1, 1) == '|' then line = line:sub(2, -1) end
            if line:sub(-1, -1) == '|' then line = line:sub(1, -2) end
            local raw_obj = host:_stat_parse(line)
            for _, metadata in pairs(raw_obj) do
                local obj = {
                    URI = metadata.URI,
                    FIELD_TYPE = metadata.FIELD_TYPE,
                    NAME = metadata.NAME,
                    ABSOLUTE_PATH = metadata.ABSOLUTE_PATH,
                    METADATA = metadata
                }
                if callback then
                    callback({type = api_flags.READ_TYPE.EXPLORE, data = {obj}, success = true})
                else
                    table.insert(children, obj)
                end
            end
            ::continue::
        end
    end
    local exit_callback = function()
        logger.debugf("Completed read of directory %s", uri:to_string('remote'))
        if #partial_output > 0 then
            logger.trace("Partial output still left to be processed after completion. Processing now...")
            -- Force cleanup of any data left
            stdout_callback(table.concat(partial_output, ''), true)
        end
        if callback then
            logger.trace("Sending complete signal to callback")
            callback({type = api_flags.READ_TYPE.EXPLORE, data = {}, success = true}, true)
        end
    end
    local stderr_callback = function(data)
        local obj = nil
        if data and data:match('[pP]ermission%s+[dD]enied') then
            -- Permission issue
            halted = true
            logger.warnf("Received permission error when trying to read %s", uri:to_string('remote'))
            obj = {
                success = false,
                message = {
                    message = "Permission Denied",
                    error = api_flags.ERRORS.PERMISSION_ERROR
                }
            }
        end
        if obj then
            if callback then
                callback(obj)
            else
                children = {obj}
            end
        else
            logger.warn("Received unhandled error", data)
        end
    end
    local async = callback and true or false
    local opts = {
        max_depth = 1,
        exec = find_cmd,
        stdout_callback = stdout_callback,
        exit_callback = exit_callback,
        stderr_callback = stderr_callback,
        async = async
    }
    local handle = M.internal.find(uri, host, opts)
    -- Assuming callback means we are doing this asynchronously
    if callback then return handle end
    -- We can't get here until we are done if we aren't running asynchronously
    return {
        success = true,
        data = children,
        type = api_flags.READ_TYPE.EXPLORE
    }
end

function M.internal.read_file(uri, host, callback)
    logger.tracef("Reading %s as file", uri:to_string('remote'))
    local halted = false
    local async = callback and true or false
    local _saved_callback = callback
    callback = function(data)
        if halted then return end
        local obj = nil
        if data.success then
            obj = {
                success = true,
                data = {
                    local_path = string.format("%s%s", local_files, uri.unique_name),
                    origin_path = uri:to_string()
                },
                type = api_flags.READ_TYPE.FILE
            }
        end
        if data.error then
            local handled = false
            if data.error:match('[pP]ermission%s+[dD]enied') then
                handled = true
                halted = true
                obj = {
                    success = false,
                    message = {
                        message = "Permission Denied",
                        error = api_flags.ERRORS.PERMISSION_ERROR
                    }
                }
            end
            if not handled then
                logger.warn("Received unhandled error", data.error)
            end
        end
        if obj then data = obj end
        if _saved_callback then
            _saved_callback(data, true)
        else
            return data
        end
    end
    local opts = {
        new_file_name = uri.unique_name,
        async = async,
        finish_callback = callback
    }
    local handle = host:get(uri, local_files, opts)
    if opts.async then
        return
        {
            type = api_flags.READ_TYPE.FILE,
            handle = handle
        }
    end
    return callback(handle)
end

--- Exposed endpoints

function M.read_a(uri, cache, callback)
    local host = nil
    if uri.__type and uri.__type == 'netman_uri' then
        uri = uri.uri
    end
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host = validation.host
    -- This should really be asynchronous
    logger.debugf("Checking type of %s to determine how to read it", uri:to_string('remote'))
    local stat = host:stat(uri, { M.internal.SSH.CONSTANTS.STAT_FLAGS.TYPE})
    if not stat.success then
        local error = "UNKNOWN_ERROR"
        if stat.error:match('No such file') then
            error = api_flags.ERRORS.ITEM_DOESNT_EXIST
        end
        return {
            success = false,
            message = {
                message = stat.error,
                error = error
            }
        }
    end
    local _ = nil
    _, stat = next(stat.data)
    if not stat then
        return {
            success = false,
            message = {
                message = string.format("Unable to find stat results for %s", uri:to_string('remote'))
            }
        }
    end
    -- If the container is running there is no reason we can't quickly stat the file in question...
    if stat.TYPE == 'directory' then
        return {
            type = api_flags.READ_TYPE.EXPLORE,
            handle = M.internal.read_directory(uri, host, callback)
        }
    else
        -- We don't support stream read type so its either a directory or a file...
        -- Idk maybe we change that if we allow archive reading but 🤷
        return {
            type = api_flags.READ_TYPE.FILE,
            handle = M.internal.read_file(uri, host, callback)
        }
    end
end

--- Reads contents from a host and returns them in the prescribed netman.api.read return format
--- @param uri string
---     The string uri to read. Can be a directory or file
--- @param cache Cache
---     The netman.api provided cache
--- @return table
---     @see :help netman.api.read for details on what this returns
function M.read(uri, cache)
    -- BUG: There seems to be a bug with the sync version of this. We are returning immediately which is wrong
    -- sleep while we wait?
    local read_return = nil
    local return_cache = {}
    local dead = false
    local _type = nil
    local callback = function(data, complete)
        if _type == api_flags.READ_TYPE.FILE then
            -- The data we get back will be a bit different
            -- if we are handling an async file pull vs a directory stream
            return_cache = data.data
            complete = true
        else
            if data and data.data then
                for _, item in ipairs(data.data) do
                    return_cache[item.URI] = item
                end
            end
        end
        if complete then read_return = return_cache end
    end
    local _ = M.read_a(uri, cache, callback)
    if not _ or not _.handle then
        local response = {
            success = false,
        }
        if _.message then
            response.message = {
                _.message
            }
        end
        return response
    end
    _type = _.type
    local handle = _.handle
    local timeout = 5000
    local kill_timer = vim.loop.new_timer()
    -- This should probably be configurable
    logger.tracef("Setting terminator for %s seconds from now", timeout / 1000)
    kill_timer:start(timeout, 0, function()
        dead = true
        logger.warn(string.format("Read Handle took too long. Killing pid %s", handle.pid))
        handle.stop()
    end)
    while not read_return and not dead do
        vim.loop.run('once')
        vim.loop.sleep(1)
    end
    kill_timer:stop()
    return {
        success = true,
        data = read_return,
        type = _type
    }
end

function M.internal.grep()

end

function M.internal.find(uri, host, opts)
    opts = opts or {}
    if not opts.exec then
        -- TODO: Why is this the default? This should be a variable that we provide when we wish to do opts.exec...
        opts.exec = 'stat -L -c \\|MODE=%f,BLOCKS=\\>%b,BLKSIZE=\\>%B,MTIME_SEC=\\>%X,USER=%U,GROUP=%G,INODE=\\>%i,PERMISSIONS=\\>%a,SIZE=\\>%s,TYPE=%F,NAME=%n\\|'
    end
    local data_cache = nil
    if opts.callback then
        opts.stdout_callback = function(data)
            if data_cache then data = data_cache .. data end
            data_cache = nil
            if opts.callback then opts.callback(data) end
        end
    end
    return host:find(uri, opts)
   end

function M.search(uri, cache, param, opts)
    opts = opts or {}
    opts.search_param = param
    local host = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host = validation.host
    return M.internal.find(uri, host, opts)
end

function M.write_a(uri, cache, data, callback)
    local host = nil
    if uri.__type and uri.__type == 'netman_uri' then
        uri = uri.uri
    end
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    logger.debug("Attempting write to", uri)
    host = validation.host
    local complete_func = function()
        callback({success = true, data = {uri = uri}}, true)
    end

    local error_func = function(message)
        message = message or "Unknown error encountered during async write"
        callback({success = false, message = { message = message}})
    end

    local stat_func = function(call_chain)
        local cb = function(response)
            logger.debug("Stat Response", response)
            if not response or not response.success or not response.data then
                local _error = response.error and response.error or string.format("Unable to locate newly created %s", uri:to_string('remote'))
                logger.warn(_error, response)
                return error_func(string.format("Unable to stat newly directory %s", uri:to_string('remote')))
            end
            local _, response_data = next(response.data)
            uri = URI:new(response_data.URI, cache)
            if call_chain and #call_chain > 0 then
                local next_call = table.remove(call_chain, 1)
                next_call(call_chain)
                return
            end
        end
        local handle = {
            handle = host:stat(uri, nil, { async = true, finish_callback = cb})
        }
        callback(handle)
        return handle
    end

    local push_data_func = function(call_chain)
        -- I wonder if we can push this into a luv work thread?
        data = data or {}
        data = table.concat(data, '')
        local local_file = string.format("%s%s", local_files, uri.unique_name)
        logger.debugf("Saving data to local file %s", local_file)
        local fh = io.open(local_file, 'w+')
        assert(fh, string.format("Unable to open local file %s for %s", local_file, uri:to_string('remote')))
        assert(fh:write(data), string.format("Unable to write to local file %s for %s", local_file, uri:to_string('remote')))
        assert(fh:flush(), string.format('Unable to save local file %s for %s', local_file, uri:to_string('remote')))
        assert(fh:close(), string.format("Unable to close local file %s for %s", local_file, uri:to_string('remote')))

        local cb = function(response)
            if not response.success then
                logger.warn(string.format("Received error while trying to upload data to %s", uri:to_string('remote')), response)
                return error_func(response.error)
            end
            if call_chain and #call_chain > 0 then
                local next_call = table.remove(call_chain, 1)
                next_call(call_chain)
            end
        end
        local write_opts = {
            finish_callback = cb,
            async = true
        }
        local handle = {
            handle = host:put(local_file, uri, write_opts)
        }
        callback(handle)
        return handle
    end

    local touch_func = function(call_chain)
        logger.debugf("Creating file %s", uri:to_string('remote'))
        local cb = function(response)
            if not response.success then
                logger.warn(string.format("Received error while trying to create %s", uri:to_string('remote')), response)
                return error_func(response.error)
            end
            if call_chain and #call_chain > 0 then
                local next_call = table.remove(call_chain, 1)
                next_call(call_chain)
                return
            end
        end
        local handle = {
            handle = host:touch(uri, {async = true, finish_callback = cb})
        }
        callback(handle)
        return handle
    end

    local mkdir_func = function(call_chain)
        logger.debugf("Creating directory %s", uri:to_string('remote'))
        local cb = function(response)
            if not response.success then
                logger.warn(string.format("Received error while trying to create %s", uri:to_string('remote')), response)
                return error_func(response.error)
            end
            if call_chain and #call_chain > 0 then
                local next_call = table.remove(call_chain, 1)
                next_call(call_chain)
                return
            end
        end
        local handle = {
            handle = host:mkdir(uri, { async = true, finish_callback = cb})
        }
        callback(handle)
        return handle
    end
    -- As a first pass POC, this _works_ but it feels icky
    -- Since this is all callback based async stuff, there
    -- probably isn't a better way to handle this :(
    if uri.type == api_flags.ATTRIBUTES.DIRECTORY then
        -- Using the observed type based on the string name
        -- as it might not exist and thus we can't stat to
        -- figure out what it is...
        return mkdir_func({stat_func, complete_func})
    else
        return touch_func({stat_func, push_data_func, complete_func})
    end
end

function M.write(uri, cache, data, opts)
    opts = opts or {}
    local handle = nil
    local dead = false
    local write_result = nil
    local cb = function(response)
        if response.success ~= nil then
            write_result = response
        end
        if response.handle then handle = response.handle end
    end
    handle = M.write_a(uri, cache, data, cb)
    -- TODO: Make this configurable??????
    local timeout = 10000
    logger.tracef("Setting terminator for %s seconds from now", timeout / 1000)
    local kill_timer = vim.loop.new_timer()
    kill_timer:start(timeout, 0, function()
        dead = true
        logger.warn(string.format("Read Handle took too long. Killing pid %s", handle.pid))
        handle.handle.stop()
    end)
    while not write_result and not dead do
        vim.loop.run('once')
        vim.loop.sleep(1)
    end
    kill_timer:stop()
    return write_result or { success = false, message = { message = "Unknown error occured during write"}}
end

function M.delete_a(uri, cache, callback)
    local host = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host = validation.host
    local handle = nil

    local rm = function(response)
        if not response or not response.success then
            local _error =
                response and response.error
                or "Unknown error occured during removal"
            callback({success = false, message = { message = _error }, true})
            return
        end
        callback({success = true}, true)
    end

    local handle_stat = function(response)
        local successful_removal = not response or (response.error and response.error:match('No such file or directory') and true)
        if successful_removal then
            callback({success = true})
            return
        end
        if response.error then
            -- Something bad happened!
            callback({success = false, message = { message = response.error or "Unknown error occured during check for location to remove"}})
            return
        end
        handle = host:rm(uri, { async = true, finish_callback = rm })
        callback({handle = handle})
    end

    handle = {
        handle = host:stat(uri, nil, { async = true, finish_callback = handle_stat})
    }
    return handle
end

function M.delete(uri, cache)
    local delete_result = nil
    local dead = false
    local timeout = 2000
    local handle = nil
    local kill_timer = vim.loop.new_timer()
    local cb = function(response)
        if response.success ~= nil then
            delete_result = response
        end
        if response.handle then handle = response.handle end
    end
    handle = M.delete_a(uri, cache, cb)
    kill_timer:start(timeout, 0, function()
        dead = true
        logger.warn(string.format("Delete handle took too long. Killing pid %s", handle.pid))
        handle.handle.stop()
    end)
    while not delete_result and not dead do
        vim.loop.run('once')
        vim.loop.sleep(1)
    end
    kill_timer:stop()
    return delete_result or { success = false, message = { message = "Unknown error occured during removal"}}
end

function M.connect_host(uri, cache)
    -- Just run connect_host_a and block until complete
    local connected = false
    local callback = function(success) connected = success end
    shell.join(M.connect_host_a(uri, cache, callback))
    return connected
end

function M.connect_host_a(uri, cache, exit_callback)
    local host = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host = validation.host
    local callback = function(response)
        local cleaned_response = {
            success = response.success,
            message = response.error and {
                message = response.error,
            }
        }
        if response.error then
            if response.error:match('Invalid/Missing Password') and utils.os_has('sshpass') then
                logger.debug("Received invalid password error. Going to try and get one now")
                local error_callback = function(password)

                    host:_set_user_password(password)
                    return true
                end
                cleaned_response.message = {
                    message = string.format("%s Password: ", host.host),
                    callback = error_callback
                }
            elseif response.error:match('[Nn]o%ssuch') then
                -- We do not care if the file doesnt' exist, we got an error from the underlying remote filesystem. Good enough
                -- to prove we are connected
                cleaned_response = { success = true }
            end
        end
        if exit_callback then
            exit_callback(cleaned_response)
        end
    end
    return host:stat(uri, nil, {
        async = true,
        finish_callback = callback
    })
end

function M.close_connection(uri, cache)
    
end

function M.get_metadata_a(uri, cache, flags, callback)
    local host = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host = validation.host
    local cb = function(response)
        if not response or not response.success or not response.data then
            local _error = string.format("Unable to get metadata for %s", uri:to_string('remote'))
            logger.warnn(_error)
            logger.error(response)
            callback({success = false, message = { message = _error }}, true)
            return
        end
        local _, stat = next(response.data)
        callback({ success = true, data = stat }, true)
    end
    return {
        handle = host:stat(uri, flags, { async = true, finish_callback = cb})
    }
end

function M.get_metadata(uri, cache, flags)
    local stat_result = nil
    local dead = false
    local timeout = 2000
    local kill_timer = vim.loop.new_timer()
    local cb = function(response)
        stat_result = response
    end
    local handle = M.get_metadata_a(uri, cache, flags, cb)
    kill_timer:start(timeout, 0, function()
        dead = true
        logger.warn(string.format("Stat handle took too long. Killing pid %s", handle.pid))
        handle.stop()
    end)
    while not stat_result and not dead do
        vim.loop.run('once')
        vim.loop.sleep(1)
    end
    kill_timer:stop()
    return stat_result or { success = false, message = { message = "Unknown error occured during stat"}}
end

function M.update_metadata(uri, cache, updates)
    -- TODO:
    local host = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host = validation.host

end

function M.copy(uris, target_uri, cache)
    local host = nil
    local validation = M.internal.validate(target_uri, cache)
    if validation.error then return validation end
    host = validation.host
    target_uri = validation.uri
    if type(uris) ~= 'table' then uris = { uris } end
    local validated_uris = {}
    for _, uri in ipairs(uris) do
        local __ = M.internal.validate(uri, cache)
        if __.error then return __ end
        if __.host ~= validation.host then
            return {
                success = false,
                message = {
                    message = string.format("%s and %s are not on the same host!", uri, target_uri)
                }
            }
        end
        table.insert(validated_uris, __.uri)
    end
    return host:cp(validated_uris, target_uri)
end

function M.move(uris, target_uri, cache)
    local host = nil
    local validation = M.internal.validate(target_uri, cache)
    if validation.error then return validation end
    host = validation.host
    target_uri = validation.uri
    if type(uris) ~= 'table' then uris = { uris } end
    local validated_uris = {}
    for _, uri in ipairs(uris) do
        local __ = M.internal.validate(uri, cache)
        if __.error then return __ end
        if __.host ~= validation.host then
            return {
                success = false,
                message = {
                    message = string.format("%s and %s are not on the same host!", uri, target_uri)
                }
            }
        end
        table.insert(validated_uris, __.uri)
    end
    return host:mv(validated_uris, target_uri)
end

function M.archive.get_a(uris, cache, archive_dump_dir, available_compression_scheme, callback)
    assert(uris, string.format("No uris provided to retrieve"))
    logger.info(string.format("Asynchronously retreiving archive of %s and storing it in %s", table.concat(uris, ', '), archive_dump_dir))
    local host = nil
    local __ = {}
    for _, uri in ipairs(uris) do
        local validation = M.internal.validate(uri, cache)
        if validation.error then return validation end
        assert(host == nil or validation.host == host,
            string.format("Host mismatch for archive! %s != %s", host, validation.host)
        )
        table.insert(__, validation.uri)
        host = validation.host
    end
    local _cb = function(response)
        if not response or not response.success then
            local message = response and response.message
                or "Unknown erorr received during archive request"
            logger.warn(message, response)
            callback({
                success = false,
                message = { message = message }
            })
            return
        end
        callback({
            success = true,
            data = {
                path = response.archive_path,
                name = response.archive_name,
                compression = response.scheme
            }
        })
    end
    logger.trace("Reaching out to host archive function")
    return host:archive(uris, archive_dump_dir, available_compression_scheme, cache, { async = true, finish_callback = _cb})
end

function M.archive.get(uris, cache, archive_dump_dir, available_compression_schemes)
    logger.info(string.format("Retrieving archive of %s and storing it in %s", table.concat(uris, ', '), archive_dump_dir))
    local get_result = nil
    local dead = false
    local timeout = 10000
    local kill_timer = vim.loop.new_timer()
    local cb = function(response)
        get_result = response
    end
    local handle = M.archive.get_a(uris, cache, archive_dump_dir, available_compression_schemes, cb)
    logger.tracef("Starting Terminator for %s milliseconds", timeout)
    kill_timer:start(timeout, 0, function()
        dead = true
        logger.warn(string.format("Get handle took too long. Killing pid %s", handle.pid))
        handle.stop()
    end)
    while not get_result and not dead do
        vim.loop.run('once')
        vim.loop.sleep(1)
    end
    kill_timer:stop()
    return get_result or { success = false, message = { message = "Unknown error occured during get"}}
end

function M.archive.put_a(uri, cache, archives, callback)
    assert(archives, string.format("No archives provided to upload to %s", uri))
    if #archives == 0 then archives = { archives } end
    local _err = string.format("Invalid archive provided to upload to %s", uri)
    for _, archive in ipairs(archives) do
        logger.trace("Validating Archive", archive)
        assert(type(archive) == 'table', _err)
        assert(archive.path, _err .. ": Missing Path attribute")
        assert(archive.compression, _err .. ": Missing Compression attribute")
        assert(archive.name, _err .. ": Missing Name attribute")
    end
    local host = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host = validation.host
    local dead = false

    local mkdir_handle = nil
    local put_handles = {}
    local extract_handles = {}
    local extract_callback = function(archive)
        extract_handles[archive] = nil
        logger.trace(string.format("Processing Extraction Output of %s", archive), extract_handles)
        -- Still extractions being processed or something dead
        if dead or next(extract_handles) then return end
        if callback then callback({success = true}) end
    end

    local extraction_function = function()
        -- We don't have the name of the put file to extract 🙃
        logger.info("Extracting remote archives")
        for _, archive in ipairs(archives) do
            extract_handles[archive.path] = host:extract(
                string.format("%s/%s", uri:to_string('local'), archive.name),
                uri,
                archive.compression,
                {
                    async = true,
                    cleanup = true,
                    finish_callback = function(response)
                        if not response or not response.success then
                            local _error = response and response.error or "Unknown error occured during archive extraction"
                            logger.warn(_error, response)
                            if callback then
                                callback({success = false, message = { message = _error}})
                            end
                            return
                        end
                        extract_callback(archive.path)
                    end
                }
            )
        end
    end

    local put_callback = function(archive)
        put_handles[archive] = nil
        -- Still puts being processed or something dead
        if dead or next(put_handles) then return end
        extraction_function()
    end

    local put_function = function()
        logger.info("Pushing archive(s) up to remote", archives)
        for _, archive in ipairs(archives) do
            logger.trace("Pushing Archive up to remote", {archive = archive})
            put_handles[archive.path] = host:put(
                archive.path,
                uri,
                {
                    new_file_name = archive.name,
                    async = true,
                    finish_callback = function(response)
                        if not response or not response.success then
                            -- Complain about failure and quit
                            local _error = response and response.error or "Unknown error occured during archive upload"
                            logger.warn(_error, response)
                            if callback then
                                callback({success = false, message = { message = _error}})
                            end
                            return
                        end
                        put_callback(archive.path)
                    end
                }
            )
        end
    end

    local mkdir_function = function()
        logger.debugf("Ensuring %s exists", uri:to_string('remote'))
        host:mkdir(
            uri,
            {
                async = true,
                finish_callback = function(response)
                    if not response or not response.success then
                        local _error = response and response.error or "Unknown error occured while creating remote directory"
                        logger.warn(_error, response)
                        if callback then
                            callback({success = false, message = { message = _error}})
                        end
                        return
                    end
                    mkdir_handle = nil
                    put_function()
                end
            }
        )
    end

    mkdir_function()
    return {
        stop = function(force)
            logger.warnf("Stopping all put activity! Force=%s", force or false)
            dead = true
            if mkdir_handle then mkdir_handle.stop(force) end
            for _, handle in pairs(put_handles) do
                handle.stop(force)
            end
            for _, handle in pairs(extract_handles) do
                handle.stop(force)
            end
        end
    }
end

function M.archive.put(uri, cache, archives)
    local put_result = nil
    local dead = false
    local timeout = 10000
    local handle = nil
    local kill_timer = vim.loop.new_timer()
    local cb = function(response)
        if response.success ~= nil then
            put_result = response
        end
    end
    handle = M.archive.put_a(uri, cache, archives, cb)
    kill_timer:start(timeout, 0, function()
        dead = true
        logger.warn(string.format("Put handle took too long. Killing pid %s", handle.pid))
        handle.stop()
    end)
    while not put_result and not dead do
        vim.loop.run('once')
        vim.loop.sleep(1)
    end
    kill_timer:stop()
    return put_result or { success = false, message = { message = "Unknown error occured during put"}}
end

function M.archive.schemes(uri, cache)
    assert(cache, string.format("No cache provided for archive scheme fetch of %s", uri))
    local host = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host = validation.host
    return host.archive_schemes
end

function M.init(config)
    if not utils.os_has('ssh') then
        return false
    end
    M.internal.prepare_config(config)
    M.internal.parse_user_sshconfig(config)
    return true
end

return M
