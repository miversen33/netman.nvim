-- TODO
-- [x] Pull and present remote directory contents in a standard format
-- [ ] Stop breaking LSP integration
-- [ ] Create files/directories remotely
-- [ ] Delete files/directories remotely
-- [ ] Handle SSH weirdness (needing passwords/passphrases will break this right now)

local log = vim.log

local utils        = require('netman.utils')
local notify       = utils.notify

local name = 'ssh' -- This is a required variable that should tell us what protocol is being used
local protocol_patterns = {
    '^sftp://',
    '^scp://',
    -- '^ssh://'
}

local user_pattern = "^(.*)@"
local host_pattern = "^([%a%c%d%s%-%.]*)"
local port_pattern = '^:([%d]+)'
local path_pattern = '^([/]+)(.*)$'
local use_compression = false
local _ssh_inited = false

local init = function(options)
    -- Optional Function that will be called on reading in providers (if exists)
    -- Use this to create global state if needed
    if _ssh_inited then
        return
    end
    if(options.compress) then
        use_compression = true
    end

    _ssh_inited = true
end

local is_valid = function(uri)
    -- Required Function that will be called anytime a remote file (of any kind)
    -- is being opened. This will be used to tell us if the remote file can be
    -- handled by _this_ provider
    local start_index, end_index
    for _, pattern in ipairs(protocol_patterns) do
        start_index, end_index = uri:find(pattern)
        if start_index then
            return true
        end
    end
    return false
end

local get_unique_name = function(remote_info)
    -- Potentially introduces a massive security vulnerability via the "remote_path" variable in 
    -- remote_info
    local command = 'ssh ' .. remote_info.auth_uri .. ' "echo \\$(hostid)\\$(stat --printf=\'%i\' ' .. remote_info.remote_path .. ')"'
    local unique_name = ''

    local stdout_callback = function(job, output)
        if unique_name == nil then return end
        for _, line in pairs(output) do
            if(unique_name == '') then
                notify('Processing: ' .. _ .. " For line: |" .. line .. '|', log.levels.INFO, true)
                unique_name = line
            elseif(line and not line:match('^(%s*)$')) then
                notify("Received invalid output -> " .. line .. " <- for unique name command!", log.levels.WARN)
                notify("Ran command: " .. command, log.levels.INFO, true)
                notify("Error Getting Remote File Information: {ENM05} -- Failed to generate unique file name for file: " .. remote_info.remote_path, log.levels.ERROR)
                unique_name = nil
                return
            end
        end
    end
    local stderr_callback = function(job, output)
        if unique_name == nil then return end
        for _, line in ipairs(output) do
            if unique_name ~= '' and line and not line:match('^(%s*)$')then
                notify("Error Getting Remote File Information: {ENM06} -- Received Remote Error: " .. line, log.levels.ERROR)
                unique_name = nil
            end
        end
    end
    notify("Generating Unique Name for file: " .. remote_info.remote_path, vim.log.levels.INFO, true)
    local job = vim.fn.jobstart(
        command
        ,{
            on_stdout = stdout_callback,
            on_stderr = stderr_callback,
        })
    vim.fn.jobwait({job})
    if unique_name == nil then
        notify("Failed to generate unique name for file", log.levels.ERROR)
        return
    end
    notify("Generated Unique Name: " .. unique_name .. " for file " .. remote_info.remote_path, vim.log.levels.DEBUG, true)
    return unique_name
end

local get_details = function(uri)
    local user, port, path_type, base_uri
    base_uri = uri
    -- This should return a table with the following info
    -- {
    --  -- REQUIRED FIELDS
    --  host, (As an IP address)
    --  remote_path, (as a string. Relative Path is acceptable)
    --  auth_uri, (a string authentication URI that can be used to authenticate via the listed protocol)
    --  -- OPTIONAL FIELDS
    --  user, (The user from the URI. This is optional)
    --  port, (The port from the URI. This is optional)
    -- }
    notify("Parsing URI: " .. base_uri, log.levels.INFO, true)
    local details = {
        host = nil,
        remote_path = nil
    }
    uri = uri:gsub('^(.*)://', '')
    notify("Post protocol URI reduction: " .. uri, log.levels.DEBUG, true)
    user = uri:match(user_pattern)
    if user ~= nil then
        details.user = user
        notify("Matched User: " .. details.user, log.levels.DEBUG, true)
        uri = uri:gsub(user_pattern, '')
        notify("Post user URI reduction: " .. uri, log.levels.DEBUG, true)
    end
    details.host = uri:match(host_pattern)
    if not details.host then
        notify("Error Parsing Host: {ENMSSH01} -- Unable to parse host from uri: " .. base_uri, log.levels.ERROR)
        return details
    end
    uri = uri:gsub(host_pattern, '')
    notify("Post host uri reduction: " .. uri, log.levels.DEBUG, true)
    port = uri:match(port_pattern)
    if port ~= nil then
        details.port = port
        notify("Matched Port: " .. details.port, log.levels.DEBUG, true)
        uri = uri:gsub(port_pattern, '')
        notify("Post port URI reduction: " .. uri, log.levels.DEBUG, true)
    end
    local path_head, path_body = uri:match(path_pattern)
    path_body = path_body or ""
    notify("Path Head Match: " .. path_head .. " -- Path Body Match: " .. path_body, log.levels.DEBUG, true) 
    if (path_head:len() ~= 1 and path_head:len() ~= 3) then
        notify("Error Parsing Remote Path: {ENMSSH02} -- Unable to parse path from uri: " .. base_uri .. ' -- Path should begin with either / (Relative) or /// (Absolute) but path begins with ' .. path_head, log.levels.ERROR)
        return details
    end
    if path_head:len() == 1 then
        details.remote_path = '$HOME/' .. path_body
    else
        details.remote_path = "/" .. path_body
    end
    notify('Path Match: ' .. details.remote_path, log.levels.DEBUG, true) -- This is likely being generated incorrectly....
    if details.user then
        details.auth_uri = details.user .. "@" .. details.host
    else
        details.auth_uri = details.host
    end
    if details.port then
        details.auth_uri = details.auth_uri .. ' -p ' .. details.port
    end
    notify("Constructed Auth URI: " .. details.auth_uri, log.levels.DEBUG, true)
    return details
end

local read_file = function(path, details)
    local compression = ''
    if(use_compression) then
        compression = '-C '
    end
    notify("Connecting to host: " .. details.host, log.levels.INFO, true)
    local command = "scp " .. compression .. details.auth_uri .. ':' .. details.remote_path .. ' ' .. details.local_file
    notify("Running Command: " .. command, log.levels.DEBUG, true)
    notify("Pulling down file: '" .. details.remote_path .. "' and saving to '" .. details.local_file .. "'", log.levels.INFO, true)
    local worked, exitcode, code = os.execute(command) -- TODO(Mike): Determine if this is "faster" than using vim.jobstart?
    code = code or ""
    if exitcode then
        notify("Error Retrieving Remote File: {ENM03} -- Failed to pull down " .. path .. "! Received exitcode: " .. exitcode .. "\n\tAdditional Details: " .. code, log.levels.ERROR)
    end
    notify("Saved Remote File: " .. details.remote_path .. " to " .. details.local_file, log.levels.DEBUG, true)
end

local read_directory = function(path, details)
    -- TODO(Mike): Add support for sorting the return info????
    details = details or get_details(path)
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
            notify("Error Browsing Remote Directory: {ENM04} -- STDERR: " .. line, log.levels.ERROR)
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
    local compression = ''
    if(use_compression) then
        compression = '-C '
    end
    local command = "scp " .. compression .. details.local_file .. ' ' .. details.auth_uri .. ':' .. details.remote_path
    notify("Updating remote file: " .. details.remote_path, log.levels.INFO)
    notify("    Running Command: " .. command, log.levels.DEBUG, true)

    local stdout_callback = function(job, output)
        for _, line in ipairs(output) do
            notify("STDOUT: " .. line, vim.log.levels.INFO, true)
        end
    end

    local stderr_callback = function(job, output)
        for _, line in ipairs(output) do
            notify("STDERR: " .. line, vim.log.levels.WARN)
        end
    end
    
    vim.fn.jobstart(command,
        {
            stdout_callback=stdout_callback,
            stderr_callback=stderr_callback
    })
    notify("Saved Remote File: " .. details.remote_path .. " to " .. details.local_file, log.levels.DEBUG, true)
    -- TODO(Mike): Consider a performant way to handle sending large files across the network
end

return {
    name           = name,           -- Required Variable
    is_valid       = is_valid,       -- Required Function
    get_details    = get_details,    -- Required Function
    read_file      = read_file,      -- Required Function
    read_directory = read_directory, -- Required Function
    write_file     = write_file,     -- Required Function
    get_unique_name=get_unique_name, -- Required Function
    init           = init,           -- Optional Function
}
