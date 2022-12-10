local socket_files = require("netman.tools.utils").socket_dir
local CACHE = require("netman.tools.cache")
local metadata_options = require("netman.tools.options").explorer.METADATA
local api_flags = require("netman.tools.options").api
local string_generator = require("netman.tools.utils").generate_string
local shell = require("netman.tools.shell")
local command_flags = shell.CONSTANTS.FLAGS
local local_files = require("netman.tools.utils").files_dir

local log = require("netman.tools.utils").log
local notify = require("netman.tools.utils").notify

local HOST_MATCH_GLOB = "^[%s]*Host[%s=](.*)"
local find_pattern_globs = {
    '^(MODE)=([%d%a]+),',
    '^(BLOCKS)=([%d]+),',
    '^(BLKSIZE)=([%d]+),',
    '^(MTIME_SEC)=([%d]+),',
    '^(USER)=([%w%-._]+),',
    '^(GROUP)=([%w%-._]+),',
    '^(INODE)=([%d]+),',
    '^(PERMISSIONS)=([%d]+),',
    '^(SIZE)=([%d]+),',
    '^(TYPE)=([%l%s]+),',
    '^(NAME)=(.*)$'
}

local M = {}
M.protocol_patterns = {'ssh', 'scp', 'sftp'}
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
        },
        SSH_CONNECTION_TIMEOUT = 10,
        SSH_SOCKET_FILE_NAME = '%h-%p-%r',
        SSH_PROTO_GLOB = '^([sftcp]+)://',
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
---     - user: string | Optional
---     - port: interger | Optional
---     - password: string | Optional (not implemented)
---     - key: string | Optional (not implemented)
---     - passphrase: string | Optional (not implemented)
--- @param provider_cache cache
---     The netman api provided cache.
---     If that confuses you, please see netman.api.register_provider for details
function SSH:new(auth_details, provider_cache)
    assert(auth_details, "No authorization details provided for new ssh object. h: netman.provider.ssh.new")
    assert(provider_cache, "No cache provided for SSH object. h: netman.providers.ssh.new")
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
        assert(new_auth_details, string.format("Unable to parse %s into a valid SSH URI. h: netman.providers.ssh.new", auth_details))
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
    _ssh.protocol = 'ssh'
    _ssh._auth_details = auth_details
    _ssh.host = _ssh._auth_details.host
    _ssh.user = _ssh._auth_details.user or ''
    _ssh.port = _ssh._auth_details.port or ''
    _ssh.__type = 'netman_provider_ssh'
    _ssh.cache = CACHE:new(CACHE.FOREVER)

    _ssh.console_command = {'ssh'}
    _ssh._put_command = { 'scp' }
    -- Intentionally leaving off the command to use for `get` as you could use either sftp or scp.
    -- The flags are the same regardless though
    _ssh._get_command = { }
    if _ssh._auth_details.port:len() > 0 then
        table.insert(_ssh.console_command, '-p')
        table.insert(_ssh._put_command, '-P')
        table.insert(_ssh.console_command, _ssh._auth_details.port)
        table.insert(_ssh._put_command, _ssh._auth_details.port)
    end
    if _ssh._auth_details.key:len() > 0 then
        table.insert(_ssh.console_command, '-i')
        table.insert(_ssh._put_command, '-i')
        table.insert(_ssh.console_command, _ssh._auth_details.key)
        table.insert(_ssh._put_command, _ssh._auth_details.key)
    end

    table.insert(_ssh.console_command, '-o')
    table.insert(_ssh.console_command, 'ControlMaster=auto')
    table.insert(_ssh._put_command, '-o')
    table.insert(_ssh._put_command, 'ControlMaster=auto')

    table.insert(_ssh.console_command, '-o')
    table.insert(_ssh.console_command, string.format('ControlPath="%s %s"', socket_files, SSH.CONSTANTS.SSH_SOCKET_FILE_NAME))
    table.insert(_ssh._put_command, '-o')
    table.insert(_ssh._put_command, string.format('ControlPath="%s %s"', socket_files, SSH.CONSTANTS.SSH_SOCKET_FILE_NAME))

    table.insert(_ssh.console_command, '-o')
    table.insert(_ssh.console_command, string.format('ControlPersist=%s', SSH.CONSTANTS.SSH_CONNECTION_TIMEOUT))
    table.insert(_ssh._put_command, '-o')
    table.insert(_ssh._put_command, string.format('ControlPersist=%s', SSH.CONSTANTS.SSH_CONNECTION_TIMEOUT))

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
    -- _ssh._archive_commands = {}
    -- _ssh._extract_commands = {}
    -- _ssh.archive_schemes = {}
    setmetatable(_ssh, self)
    provider_cache:add_item(cache_key, _ssh)
    return _ssh
end

function SSH:_get_os()
    log.trace(string.format("Checking OS For Host %s", self.name))
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

function SSH:_get_archive_availability_details()
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
        if location:sub(1,1) ~= '/' then
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
function SSH:run_command(command, opts)
    -- It might be easier if we put some hooks into docker to
    -- listen for changes to the container...?
    opts = opts or {
        [command_flags.STDOUT_JOIN] = '',
        [command_flags.STDERR_JOIN] = ''
    }
    local pre_command = { }
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
        log.error(string.format("I have no idea what I am supposed to do with %s", command),
            { type = type(command), command = command })
        return { exit_code = -1, stderr = "Invalid command passed to netman ssh !", stdout = '' }
    end
    local _command = { }
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
    log.trace(_shell:dump_self_to_table())
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
--- @param opts table | Optional
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
    -- TODO
    -- if opts.remote_dump then
    --     -- This probably doesn't work
    --     compress_command = string.format("mkdir -p %s && %s > %s/%s", archive_dir, compress_command, archive_dir,
    --         archive_name)
    --     archive_path = string.format("ssh://%s///%s/%s", self.host, archive_dir, archive_name)
    -- else
    command_options[command_flags.STDOUT_FILE] = string.format("%s/%s", archive_dir, archive_name)
    -- end
    self:run_command(compress_command, command_options)
    if not opts.async then return return_details end
end

--- Extracts the provided archive into the target location in the host
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
---             Indicates that the archive is already on the host
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
---     local host = SSH:new('user@host')
---     host:extract('/tmp/some.tar.gz', '/tmp/', 'tar.gz', cache)
---     -- TODO: Add an example of how to do an extract with a Pipe...
function SSH:extract(archive, target_dir, scheme, provider_cache, opts)
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
        if not target_dir:match(SSH.CONSTANTS.SSH_PROTO_GLOB) then
            -- A little bit of uri coalescing
            ---@diagnostic disable-next-line: cast-local-type
            target_dir = self:_create_uri(target_dir)
        end
        target_dir = URI:new(target_dir)
    end
    assert(target_dir.__type and target_dir.__type == 'netman_uri',
        string.format("%s is not a valid netman uri", target_dir))
    -- If the archive isn't remote, we will want to craft a different command to extract it.
    local extract_command = nil
    local cleanup = nil
    local mkdir_status = self:mkdir(target_dir, { force = true })
    if not mkdir_status or not mkdir_status.success then
        return_details = { success = false, error = mkdir_status.error or SSH.CONSTANTS.MKDIR_UNKNOWN_ERROR }
        if opts.finish_callback then
            opts.finish_callback(return_details)
            return
        end
        return return_details
    end
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
        extract_command = {}
        for _, _command in ipairs(self.console_command) do
            table.insert(extract_command, _command)
        end
        table.insert(extract_command, '/bin/sh')
        table.insert(extract_command, '-c')
        table.insert(extract_command, string.format("'%s'", extraction_function(target_dir, '-')))
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
            stream = fh:read(SSH.CONSTANTS.IO_BYTE_LIMIT)
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

--- Moves a location to another location in the ssh
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
---     local host = SSH:new('someuser@somehost')
---     host:mv('/tmp/testfile.txt', '/tmp/testfile2.txt')
function SSH:mv(locations, target_location, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = {locations} end
    if target_location.__type and target_location.__type == 'netman_uri' then target_location = target_location:to_string() end
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
---     local host = SSH:new('someuser@somehost')
---     host:touch('/tmp/testfile.txt')
function SSH:touch(locations, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    local touch_command = {"touch"}
    local __ = {}
    for _, location in ipairs(locations) do
        if location.__type and location.__type == 'netman_uri' then location = location:to_string() end
        table.insert(touch_command, location)
        table.insert(__, location)
    end
    locations = __
    local output = self:run_command(touch_command, { no_shell = true })
    if output.exit_code ~= 0 and not opts.ignore_errors then
        local _error = string.format("Unable to touch %s", table.concat(locations, ' '))
        log.warn(_error, { exit_code = output.exit_code, error = output.stderr })
        return { success = false, error = _error }
    end
    return { success = true }
end

--- Creates a directory in the host
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
---     local host = SSH:new('someuser@somehost')
---     host:mkdir('/tmp/testdir1')
function SSH:mkdir(locations, opts)
    opts = opts or {}
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
---     A list of key/value pair options that can be used to tailor how rm does "things". Valid key/value pairs are
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
---     local host = SSH:new('someuser@somehost')
---     host:rm('/tmp/somedir')
---     -- You can also provide the `force` flag to force removal of a directory
---     host:rm('/tmp/somedir', {force=true})
---     -- You can also also provide the `ignore_errors` flag if you don't care if this
---     -- works or not
---     host:rm('/tmp/somedir', {ignore_errors=true})
function SSH:rm(locations, opts)
    opts = opts or {}
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    local rm_command = {'rm', '-r'}
    if opts.force then table.insert(rm_command, '-f') end
    local __ = {}
    for _, location in ipairs(locations) do
        if type(location) == 'string' then
            if not location:match(SSH.CONSTANTS.SSH_PROTO_GLOB) then
                -- A little bit of uri coalescing
                ---@diagnostic disable-next-line: cast-local-type
                location = self:_create_uri(location)
            end
            location= URI:new(location)
        end
        assert(location.__type and location.__type == 'netman_uri', string.format("%s is not a valid netman uri", location))
        table.insert(rm_command, location:to_string())
        table.insert(__, location:to_string())
    end
    locations = __
    local output = self:run_command(rm_command, { no_shell = true })
    if output.exit_code ~= 0 and not opts.ignore_errors then
        local _error = string.format("Unable to remove %s", table.concat(locations, ' '))
        log.error(_error, { exit_code = output.exit_code, error = output.stderr })
        return { success = false, error = _error }
    end
    return { success = true }
end

--- Runs find within the host
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
--- @return table
---     Returns the return value of @see SSH:run_command
function SSH:find(location, opts)
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
            error(string.format("Invalid Find Pattern Type: %s. See :h netman.providers.ssh.find for details", opts.pattern_type))
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

--- Uploads a file to the host, placing it in the provided location
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
---     local host = SSH:new('someuser@somehost')
---     host:put('/tmp/ubuntu.tar.gz', '/tmp/ubuntu')
function SSH:put(file, location, opts)
    opts = opts or {}
    local return_details = {}
    assert(vim.loop.fs_stat(file), string.format("Unable to location %s", file))
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
        local _error = string.format("Unable to verify that %s is a directory, you might see errors!", location:to_string())
        local status, ___ = pcall(SSH.stat, self, location, {SSH.CONSTANTS.STAT_FLAGS.TYPE})
        -- Running this in protected mode because `location` may not exist. If it doesn't we will get an error,
        -- we don't actually care about the error we get, we are going to assume that the location doesn't exist
        -- if we get an error. Thus, error == gud
        if status == true then
            local _, _stat = next(___)
            if _stat.TYPE ~= 'directory' then
                log.warn(_error)
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
    shell:new(copy_command, command_options):run()
    if not opts.async then return return_details end
end

--- Retrieves a file from the host and saves it in the output directory
--- NOTE: This can only be used to retrieve files. Directories must be archived with @see SSH:archive
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
---     local host = SSH:new('someuser@somehost')
---     host:get('/tmp/ubuntu.tar.gz', '/tmp/')
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
        copy_command = { }
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
---     local host = SSH:new('someuser@somehost')
---     print(vim.inspect(host:stat('/tmp')))
function SSH:stat(locations, target_flags)
    -- Coerce into a table for iteration
    if type(locations) ~= 'table' or #locations == 0 then locations = { locations } end
    local stat_flags = {
        '-L',
        '-c',
        'MODE=%f,BLOCKS=%b,BLKSIZE=%B,MTIME_SEC=%X,USER=%U,GROUP=%G,INODE=%i,PERMISSIONS=%a,SIZE=%s,TYPE=%F,NAME=%n\\\\0'
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
    -- stat_command = {'/bin/sh', '-c', string.format("'%s'", table.concat(stat_command, ' '))}
    local stat_details = self:run_command(stat_command, {[command_flags.STDERR_JOIN] = ''})
    if stat_details.exit_code ~= 0 then
        -- Complain about stat failure??
        log.warn(string.format("Unable to get stat details for %s", table.concat(locations, ', '),
            { error = stat_details.stderr, exit_code = stat_details.exit_code }))
        return {}
    end
    --TODO: (Mike) Consider caching this for a short amount of time????
    return self:_stat_parse(stat_details.stdout, target_flags)
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
        if not __[SSH.CONSTANTS.STAT_FLAGS['NAME']] then __[SSH.CONSTANTS.STAT_FLAGS['NAME']] = SSH.CONSTANTS.STAT_FLAGS.NAME end
        target_flags = __
    end
    if type(stat_output) == 'string' then stat_output = {stat_output} end
    local stat = {}
    for _, line in ipairs(stat_output) do
        line = line:gsub('(\\0)', '')
        local item = {}
        if target_flags[SSH.CONSTANTS.STAT_FLAGS.RAW] then
            item[SSH.CONSTANTS.STAT_FLAGS.RAW] = line
        end
        local _type = nil
        for _, pattern in ipairs(find_pattern_globs) do
            local key, value = line:match(pattern)
            line = line:gsub(pattern, '')
            if target_flags[key:upper()] then
                item[key:upper()] = value
            end
            if not _type and key:upper() == SSH.CONSTANTS.STAT_FLAGS.TYPE then
                _type = value
            end
        end
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
        log.warn("Received Error trying to modify permissions")
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
    if _uri.user:len() > 0  then
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
    assert(uri:match('^///') or uri:match('^/'), string.format("Invalid URI: %s Path start with either /// or /", _uri.uri))
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
    log.warn(string.format("Invalid URI to_string style %s", style))
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

--- Returns the various containers that are currently available on the system
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
---     Returns a 1 dimensional table with the followin gkey value pairs in it
---     - NAME
---     - URI
---     - STATE
function M.ui.get_host_details(config, host, provider_cache)
    SSH:new(host, provider_cache)
    return {
        NAME = host,
        URI = string.format("ssh://%s///", host),
    }
end

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
        if host then
            -- Removing any trailing padding
            host = host:gsub('[%s]*$', '')
            log.trace(string.format("Processing SSH host: %s", host))
            if host ~= '*' and not hosts[host] then
                hosts[host] = {}
            end
        end
    end
    config:save()
end

--- Exposed endpoints

function M.internal.validate(uri, cache)
    assert(cache, string.format("No cache provided for read of %s",  uri))
    ---@diagnostic disable-next-line: cast-local-type
    uri = M.internal.URI:new(uri, cache)
    local host = M.internal.SSH:new(uri, cache)
    return {uri = uri, host = host}
end

function M.internal.read_directory(uri, host)
    local raw_children = host:find(uri,
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
    local children = host:_stat_parse(raw_children)
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

function M.internal.read_file(uri, host)
    local status = host:get(uri, local_files, {new_file_name = uri.unique_name})
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

--- Reads contents from a host and returns them in the prescribed netman.api.read return format
--- @param uri string
---     The string uri to read. Can be a directory or file
--- @param cache Cache
---     The netman.api provided cache
--- @return table
---     @see :help netman.api.read for details on what this returns
function M.read(uri, cache)
    local host = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host = validation.host
    local _, stat = next(host:stat(uri, {M.internal.SSH.CONSTANTS.STAT_FLAGS.TYPE}))
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
        return M.internal.read_directory(uri, host)
    else
        -- We don't support stream read type so its either a directory or a file...
        -- Idk maybe we change that if we allow archive reading but 🤷
        return M.internal.read_file(uri, host)
    end
end

function M.write(uri, cache, data, opts)
    opts = opts or {}
    local host = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host = validation.host
    if uri.type == api_flags.ATTRIBUTES.DIRECTORY then
        local _ = host:mkdir(uri)
        if not _.success then
            return {
                success = false, error = { message = _.error }
            }
        end
        local _ = host:stat(uri)
        if not _ then
            return {
                success = false, error = { message = string.format("Unable to stat newly created %s", uri:to_string())}
            }
        end
        local _, _stat = next(_)
        return {
            success = true, uri = _stat.URI
        }
    end
    -- Lets make sure the file exists?
    local _ = host:touch(uri)
    if not _.success then
        return { success = false, error = { message = _.error or string.format("Unable to create %s", uri)}}
    end
    data = data or {}
    data = table.concat(data, '')
    local local_file = string.format("%s%s", local_files, uri.unique_name)
    local fh = io.open(local_file, 'w+')
    assert(fh, string.format("Unable to open local file %s for %s", local_file, uri:to_string('remote')))
    assert(fh:write(data), string.format("Unable to write to local file %s for %s", local_file, uri:to_string('remote')))
    assert(fh:flush(), string.format('Unable to save local file %s for %s', local_file, uri:to_string('remote')))
    assert(fh:close(), string.format("Unable to close local file %s for %s", local_file, uri:to_string('remote')))
    local return_details = nil
    local finish_callback = function(status)
        return_details = status
        if status.error then
            return_details = {
                success = false,
                error = {
                    message = status.error
                }
            }
            return
        end
        local ___ = host:stat(uri)
        local _, stat = next(___)
        if not _ then
            return_details = {
                success = false, error = { message = string.format("Unable to stat newly created %s", uri:to_string())}
            }
        else
            return_details = {
                success = true,
                uri = stat.URI
            }
        end
        -- Provide a way to return this inside this callback if the user reqeusts it
        -- return return_details
    end
    local write_opts = {
        finish_callback = finish_callback,
        async = opts.async or false
    }
    local _ = host:put(local_file, uri, write_opts)
    if not _.success then
        return_details = { uri = return_details.uri or nil, success = false, error = { message = _.error } }
    end
    return return_details
end

function M.delete(uri, cache)
    local host = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host = validation.host
    return host:rm(uri, {force = true})
end

function M.get_metadata(uri, cache)
    local host = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host = validation.host
    return host:stat(uri)
end

function M.update_metadata(uri, cache, updates)
    -- TODO:
    local host = nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host = validation.host

end

function M.move(uris, target_uri, cache)
    local host = nil
    local validation = M.internal.validate(target_uri, cache)
    if validation.error then return validation end
    host = validation.host
    target_uri = validation.uri
    if type(uris) ~= 'table' then uris = {uris} end
    local validated_uris = {}
    for _, uri in ipairs(uris) do
        local __ = M.internal.validate(uri, cache)
        if __.error then return __ end
        if __.host ~= validation.host then
            return {
                success = false,
                error = string.format("%s and %s are not on the same host!", uri, target_uri)
        }
        end
        table.insert(validated_uris, __.uri)
    end
    return host:mv(validated_uris, target_uri)
end

function M.archive.get(uris, cache, archive_dump_dir, available_compression_schemes)
    if type(uris) ~= 'table' or #uris == 0 then uris = {uris} end
    local host= nil
    local __ = {}
    for _, uri in ipairs(uris) do
        local validation = M.internal.validate(uri, cache)
        if validation.error then return validation end
        assert(host== nil or validation.host== host, string.format("Host mismatch for archive! %s != %s", host, validation.host))
        table.insert(__, validation.uri)

        host= validation.host
    end
    uris = __
    return host:archive(uris, archive_dump_dir, available_compression_schemes, cache)
end

function M.archive.put(uri, cache, archive, compression_scheme)
    assert(archive, string.format("Invalid Archive provided for upload to %s", uri))
    local host= nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host= validation.host
    return host:extract(archive, uri, compression_scheme, cache)
end

function M.archive.schemes(uri, cache)
    assert(cache, string.format("No cache provided for archive scheme fetch of %s", uri))
    local host= nil
    local validation = M.internal.validate(uri, cache)
    if validation.error then return validation end
    uri = validation.uri
    host= validation.host
    return host.archive_schemes
end

function M.init(config)
    M.internal.prepare_config(config)
    M.internal.parse_user_sshconfig(config)
    return true
end

return M
