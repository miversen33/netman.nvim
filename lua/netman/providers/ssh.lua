-- TODO
-- [x] Pull and present remote directory contents in a standard format
-- [x] Create files remotely
-- [x] Cleanup Documentation
-- [x] Create directories
-- [x] Delete files remotely
-- [x] Delete directories remotely
-- [ ] Handle SSH weirdness (needing passwords/passphrases will break this right now)
-- [ ] Cleanup errors

local utils        = require('netman.utils')

local name = 'ssh' -- This is a required variable that should tell us what protocol is being used
local protocol_patterns = { -- This is the list of patterns to apply to the buffer/file autocommands
    'sftp',
    'scp',
    -- 'ssh',
}
local version = '0.9' -- Required variable that is used for logging/diagnostics

local user_pattern = "^(.*)@"
local host_pattern = "^([%a%c%d%s%-%.]*)"
local port_pattern = '^:([%d]+)'
local path_pattern = '^([/]+)(.*)$'
local use_compression = false
local _ssh_inited = false

local init = function(options)
    -- init is the startup function for your provider. Note: This is an optional function and does not need to exist or have any contents
    -- :param options(Table):
    --     A table that contains all startup/default options provided by the netman initialization. View the current spec for this TODO(Mike): HERE
    if _ssh_inited then
        return
    end
    if(options.compress) then
        use_compression = true
    end

    _ssh_inited = true
end

local get_unique_name = function(remote_info)
    -- Required function that will be called anytime a new file is opened with this protocol. This should return
    -- a "unique" recreatable name for a remote file. Ensure that the unique name is _not_ random
    -- as this name will be used for locking the file locally. See below for an example of how this was
    -- done with ssh

    -- get_unique_name (called via netman.remote_tools) used when loading/locking a file
    -- :param path (String):
    --     The path to which we want a unique name generated for
    -- :param remote_info (table):
    --     A table containing the details as provided back from @see get_details
    -- :return String:
    --     Return either a string which is the unique name of the input file, or nil if it is not possible to
    --     create a unique name.
    --     Do not worry if the remote file does not exist, do not do any fancy error handling to compensate for this
    --     Just return a unique name if its possible to create

    -- Potentially introduces a massive security vulnerability via the "remote_path" variable in
    -- remote_info
    local command = 'ssh ' .. remote_info.auth_uri .. ' "echo \\$(hostid)-\\$(stat --printf=\'%i\' ' .. remote_info.remote_path .. ')"'
    local unique_name = ''

    local stdout_callback = function(job, output)
        if unique_name == nil then return end
        for _, line in pairs(output) do
            if(unique_name == '') then
                unique_name = line
            elseif(line and not line:match('^(%s*)$')) then
                utils.notify.warn("Received invalid output -> " .. line .. " <- for unique name command!")
                utils.log.info("Ran command: " .. command)
                utils.notify.error("Error Getting Remote File Information: {ENM05} -- Failed to generate unique file name for file: " .. remote_info.remote_path)
                unique_name = nil
                return
            end
        end
    end
    local stderr_callback = function(job, output)
        if unique_name == nil then return end
        for _, line in ipairs(output) do
            if unique_name ~= '' and line and not line:match('^(%s*)$')then
                utils.log.warn("Error Getting Remote File Information: {ENM06} -- Received Remote Error: " .. line)
                -- TODO(Mike): Specifically check if the string `No such file or directory` is in the error. If this is a permission error we should let the user know, but if the file doesn't exist, we can just ignore this
                unique_name = nil
                return
            end
        end
    end
    utils.log.info("Generating Unique Name for file: " .. remote_info.remote_path)
    local job = vim.fn.jobstart(
        command
        ,{
            on_stdout = stdout_callback,
            on_stderr = stderr_callback,
        })
    vim.fn.jobwait({job})
    if unique_name == nil then
        utils.log.warn("Failed to generate unique name for file")
        return unique_name
    end
    utils.log.debug("Generated Unique Name: " .. unique_name .. " for file " .. remote_info.remote_path)
    local hostid, fileid = unique_name:match('^([%d%a]+)-(%d+)$')
    if not hostid or not fileid then
        utils.log.warn("Failed to validate unique name for file")
        return nil
    end
    return unique_name
end

local get_details = function(uri)
    -- get_details is used to open a details about a remote file/directory
    -- :param uri(String):
    --     A string representation of a remote location. This will will be the full remote URI ($PROTOCOL://[[$USERNAME@]$HOSTNAME[:$PORT]/[//][$PATH]).
    --     EG: sftp://user@my-remote-host/file_located_in_user_home_directory.txt
    --     OR: sftp://user@my-remote-host///tmp/file_located_not_in_user_home_directory.txt
    -- :return:
    -- {
    --  -- REQUIRED FIELDS
    --  host, (As an IP address)
    --  remote_path, (as a string. Relative Path is acceptable)
    --  auth_uri, (a string authentication URI that can be used to authenticate via the listed protocol)
    --  local_file, (set this to nil, it will be set later)
    --  local_file_name, (set this to nil, it will be set later)
    --  provider, (set this to nil, it will be set later)
    --  protocol, (set this to your global (required) name value)
    --  buffer, (set this to nil, it will be set later)
    --  is_dummy, (set this to nil, this is reserved for potential later use)

    --  -- OPTIONAL FIELDS
    --  user, (The user from the URI. This is optional)
    --  port, (The port from the URI. This is optional)
    -- }
    -- NOTES:
    --     Consider having the provider cache the various URI resolutions for future use
    local user, port, base_uri
    base_uri = uri
    utils.log.info("Parsing URI: " .. base_uri)
    local details = {
        host = nil,
        remote_path = nil
    }
    uri = uri:gsub('^(.*)://', '')
    utils.log.debug("Post protocol URI reduction: " .. uri)
    user = uri:match(user_pattern)
    if user ~= nil then
        details.user = user
        utils.log.debug("Matched User: " .. details.user)
        uri = uri:gsub(user_pattern, '')
        utils.log.debug("Post user URI reduction: " .. uri)
    end
    details.host = uri:match(host_pattern)
    if not details.host then
        utils.notify.error("Error Parsing Host: {ENMSSH01} -- Unable to parse host from uri: " .. base_uri)
        return details
    end
    uri = uri:gsub(host_pattern, '')
    utils.log.debug("Post host uri reduction: " .. uri)
    port = uri:match(port_pattern)
    if port ~= nil then
        details.port = port
        utils.log.debug("Matched Port: " .. details.port)
        uri = uri:gsub(port_pattern, '')
        utils.log.debug("Post port URI reduction: " .. uri)
    end
    local path_head, path_body = uri:match(path_pattern)
    path_body = path_body or ""
    utils.log.debug("Path Head Match: " .. path_head .. " -- Path Body Match: " .. path_body)
    if (path_head:len() ~= 1 and path_head:len() ~= 3) then
        utils.notify.error("Error Parsing Remote Path: {ENMSSH02} -- Unable to parse path from uri: " .. base_uri .. ' -- Path should begin with either / (Relative) or /// (Absolute) but path begins with ' .. path_head)
        return details
    end
    if path_head:len() == 1 then
        details.remote_path = "'$HOME/'" .. path_body
    else
        details.remote_path = "/" .. path_body
    end
    utils.log.debug('Path Match: ' .. details.remote_path)
    if details.user then
        details.auth_uri = details.user .. "@" .. details.host
    else
        details.auth_uri = details.host
    end
    if details.port then
        details.auth_uri = details.auth_uri .. ' -p ' .. details.port
    end
    details.local_file = nil
    details.protocol = name
    details.buffer   = nil
    details.provider = nil
    details.local_file_name = nil
    details.is_dummy = nil
    utils.log.debug("Constructed Auth URI: " .. details.auth_uri)
    return details
end

local read_file = function(details)
    -- read_file is used to fetch and save a remote file locally
    -- :param details(Table):
    --     A Table representing the remote file details as returned via @see get_remote_details

    local compression = ''
    if(use_compression) then
        compression = '-C '
    end
    utils.log.info("Connecting to host: " .. details.host)
    local command = "scp " .. compression .. details.auth_uri .. ':' .. details.remote_path .. ' ' .. details.local_file
    utils.log.debug("Running Command: " .. command)
    utils.log.info("Pulling down file: '" .. details.remote_path .. "' and saving to '" .. details.local_file .. "'")
    local _, exitcode, code = os.execute(command) -- TODO(Mike): Determine if this is "faster" than using vim.jobstart?
    code = code or ""
    if exitcode then
        utils.notify.error("Error Retrieving Remote File: {ENM03} -- Failed to pull down " .. details.remote_path .. "! Received exitcode: " .. exitcode .. "\n\tAdditional Details: " .. code)
    end
    utils.log.debug("Saved Remote File: " .. details.remote_path .. " to " .. details.local_file)
end

local read_directory = function(details)
    -- read_directory is used to fetch the contents of a remote directory
    -- :param details(Table):
    --     A Table representing the remote file details as returned via @see get_remote_details

    -- TODO(Mike): Add support for sorting the return info????
    local remote_files = {
        dirs  = {
            hidden = {},
            visible = {}
        },
        files = {
            hidden = {},
            visible = {},
        },
        links = { -- TODO(Mike): Command right now does _not_ resolve links locations.
            hidden = {},
            visible = {}
        }
    }
    local stdout_callback = function(job, output)
        for _, line in ipairs(output) do
            local _,_, type = line:find('^(%a)')
            line = line:gsub('^(%a)|', "")
            local _,_, is_empty = line:find('^[%s]*$')
            if not line or line:len() == 0 or is_empty then goto continue end
            local is_hidden,_ = line:find('^%.')
            local store_table = nil
            if type == 'd' then
                if is_hidden then
                    store_table = remote_files.dirs.hidden
                else
                    store_table = remote_files.dirs.visible
                end
            elseif type == 'f' then
                if is_hidden then
                    store_table = remote_files.files.hidden
                else
                    store_table = remote_files.files.visible
                end
            elseif type == 'N' then
                if is_hidden then
                    store_table = remote_files.links.hidden
                else
                    store_table = remote_files.links.visible
                end
            end
            if store_table then
                table.insert(store_table, {
                    relative_path = line,
                    full_path = details.remote_path .. line
                })
            end
        ::continue::
        end
    end
    local stderr_callback = function(job, output)
        for _, line in ipairs(output) do
            if not line or line:len() == 0 then goto continue end
            utils.notify.error("Error Browsing Remote Directory: {ENM04} -- STDERR: " .. line)
            ::continue::
        end
    end
    local command = 'ssh ' .. details.auth_uri .. ' "find ' .. details.remote_path .. ' -maxdepth 1 -printf \'%Y|%P\n\' | gzip -c" | gzip -d -c'

    local job = vim.fn.jobstart(
        command
        ,{
            on_stdout = stdout_callback,
            on_stderr = stderr_callback,
        })
    vim.fn.jobwait({job})
    return remote_files
end

local write_file = function(details)
    -- write_file is used to push a local file to a remote location
    -- :param details(Table):
    --     A Table representing the remote file details as returned via @see get_remote_details

    local compression = ''
    if(use_compression) then
        compression = '-C '
    end
    local command = "scp " .. compression .. details.local_file .. ' ' .. details.auth_uri .. ':' .. details.remote_path
    utils.notify.info("Updating remote file: " .. details.remote_path)
    utils.log.debug("    Running Command: " .. command)

    local stdout_callback = function(job, output)
        for _, line in ipairs(output) do
            utils.log.info("STDOUT: " .. line)
        end
    end

    local stderr_callback = function(job, output)
        for _, line in ipairs(output) do
            utils.notify.warn("STDERR: " .. line)
        end
    end

    vim.fn.jobstart(command,
        {
            stdout_callback=stdout_callback,
            stderr_callback=stderr_callback
    })
    utils.log.debug("Saved Remote File: " .. details.remote_path .. " to " .. details.local_file)
    -- TODO(Mike): Consider a performant way to handle sending large files across the network
end

local create_directory = function(details, new_directory_name, permissions)
    -- create_directory is used to create a remote directory
    -- :param details(Table):
    --     A Table representating the remote file details as returned via @see get_remote_details
    -- :param new_directory_name(String):
    --     The string name (as full absolute path) of the directory to create

    permissions = permissions or ""
    local command = "ssh " .. details.auth_uri .. ' "mkdir ' .. new_directory_name .. '"'
    local completed_successfully = true

    utils.notify.info("Creating remote directory " .. new_directory_name)
    utils.log.debug("    Command: " .. command)

    local stdout_callback = function(job, output)
        for _, line in ipairs(output) do
            utils.log.info("    STDOUT: " .. line)
        end
    end

    local stderr_callback = function(job, output)
        for _, line in ipairs(output) do
            utils.log.warn("    STDERR: " .. line)
        end
        completed_successfully = false
    end

    vim.fn.jobwait({vim.fn.jobstart(command,
        {
            stdout_callback=stdout_callback,
            stderr_callback=stderr_callback
        })
    })
    if not completed_successfully then
        utils.notify.error("Failed to create directory: " .. new_directory_name .. '! Check logs for more details')
    else
        utils.notify.info("Created " .. new_directory_name .. " successfully")
    end
end

local delete_file = function(details, file_name)
    -- delete_file is used to delete a remote file
    -- :param details(Table):
    --     A Table representating the remote file details as returned via @see get_remote_details
    -- :param file_name(String):
    --     The string name (as full absolute path) of the file to delete

    local command = "ssh " .. details.auth_uri .. ' "rm ' .. file_name .. '"'
    local completed_successfully = true

    utils.notify.info("Removing remote file " .. file_name)
    utils.log.debug("    Command: " .. command)

    local stdout_callback = function(job, output)
        for _, line in ipairs(output) do
            utils.log.info("    STDOUT: " .. line)
        end
    end

    local stderr_callback = function(job, output)
        for _, line in ipairs(output) do
            utils.log.warn("    STDERR: " .. line)
        end
        completed_successfully = false
    end

    vim.fn.jobwait({vim.fn.jobstart(command,
        {
            stdout_callback=stdout_callback,
            stderr_callback=stderr_callback
        })
    })
    if not completed_successfully then
        utils.notify.error("Failed to remove file: " .. file_name .. '! Check logs for more details')
    else
        utils.log.info("Removed " .. file_name .. " successfully")
    end

end

local delete_directory = function(details, directory)
    -- delete_directory is used to delete a remote directory
    -- :param details(Table):
    --     A Table representating the remote file details as returned via @see get_remote_details
    -- :param directory(String):
    --     The string name (as full absolute path) of the directory to delete

    local command = "ssh " .. details.auth_uri .. ' "rm -r ' .. directory .. '"'
    local completed_successfully = true

    utils.log.info("Removing remote directory " .. directory )
    utils.log.debug("    Command: " .. command)

    local stdout_callback = function(job, output)
        for _, line in ipairs(output) do
            utils.log.info("    STDOUT: " .. line)
        end
    end

    local stderr_callback = function(job, output)
        for _, line in ipairs(output) do
            utils.log.warn("    STDERR: " .. line)
        end
        completed_successfully = false
    end

    vim.fn.jobwait({vim.fn.jobstart(command,
        {
            stdout_callback=stdout_callback,
            stderr_callback=stderr_callback
        })
    })
    if not completed_successfully then
        utils.notify.error("Failed to remove directory: " .. directory .. '! Check logs for more details')
    else
        utils.log.info("Removed " .. directory .. " successfully")
    end

end

return {
    name              = name,              -- Required Variable
    protocol_patterns = protocol_patterns, -- Required Variable
    version           = version,           -- Required Variable
    -- State management/setup functions
    get_details       = get_details,       -- Required Function
    get_unique_name   = get_unique_name,   -- Required Function
    init              = init,              -- Optional Function
    -- Remote Filesystem touching functions
    read_file         = read_file,         -- Required Function
    read_directory    = read_directory,    -- Required Function
    write_file        = write_file,        -- Required Function
    create_directory  = create_directory,  -- Required Function
    delete_file       = delete_file,       -- Required Function
    delete_directory  = delete_directory,  -- Required Function
}
