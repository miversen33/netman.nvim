local split  = vim.fn.split
local log    = vim.log

local utils = require('netman.utils')
local notify = utils.notify

local protocol_patterns = {
    sftp = {
        regex = '^sftp',
        cmd = "ssh"
    },
    scp = {
        regex = '^scp',
        cmd = "ssh"
    }
}

local user_pattern = "^(.*)@"
local host_pattern = "^([%a%c%d%s%-%.]*)([/]+)"

local get_remote_details = function(uri)
    local _, path_type
    local remote_info = {
        protocol    = nil,
        user        = nil,
        host        = nil,
        remote_path = nil,
        path        = nil,
        auth_uri    = nil,
        uri         = uri,
        is_file     = false,
        is_dir      = false
    }

    for key, p in pairs(protocol_patterns) do
        uri, _ = uri:gsub(p.regex .. "://", "")
        if(_ ~= 0) then
            remote_info.protocol = key
            break
        end
    end
    if(remote_info.protocol == nil) then
        local valid_protocols = nil
        for key, _ in pairs(protocol_patterns) do
            if valid_protocols then
                valid_protocols = valid_protocols .. ", " .. key
            else
                valid_protocols = "(" .. key
            end
        end
        if valid_protocols then
            valid_protocols = valid_protocols .. ")"
        end
        notify('Error Parsing Remote Protocol: {ENM05} -- ' .. 'Netman only supports ' .. valid_protocols .. ' but received protocol ' .. uri, log.levels.ERROR)
        return remote_info
    end

    _, _, remote_info.user = uri:find(user_pattern)
    if(remote_info.user ~= nil) then
        uri = uri:gsub(user_pattern, "")
    end
    _, _, remote_info.host, path_type = uri:find(host_pattern)
    if(remote_info.host ~= nil) then
        uri = uri:gsub(host_pattern, "")
    else
        notify("Error Reading Remote URI: {ENM01} -- " .. remote_info.uri .. "\n -- Consider checking the host definition", log.levels.ERROR)
        return {}
    end
    if(path_type ~= nil) then
        if(path_type:len() > 1) then
            path_type = "absolute"
        else
            path_type = "relative"
        end
    else
        notify("Error Reading Remote URI: {ENM02} -- " .. remote_info.uri .. "\n -- Consider checking the path definition", log.levels.ERROR)
        return {}
    end
    print("Processing URI: " .. uri)
    if(path_type == "relative") then
        remote_info.remote_path = "$HOME/"
    else
        remote_info.remote_path = "/"
    end
    if(uri) then
        remote_info.remote_path = remote_info.remote_path .. uri
        remote_info.path = uri
    end
    if remote_info.user then
        remote_info.auth_uri = remote_info.user .. "@" .. remote_info.host
    else
        remote_info.auth_uri = remote_info.host
    end
    if remote_info.remote_path:sub(-1) == '/' then
        remote_info.is_dir = true
    else
        remote_info.is_file = true
    end
    return remote_info
end

local get_remote_files = function(remote_info, path)
    remote_info = remote_info or get_remote_details(path)
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
                    full_path = remote_info.remote_path .. line
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
    local command = 'ssh ' .. remote_info.auth_uri .. ' "find ' .. remote_info.remote_path .. ' -maxdepth 1 -printf \'%Y|%P\n\' | gzip -c" | gzip -d -c'

    local job = vim.fn.jobstart(
        command
        ,{
            on_stdout = stdout_callback,
            on_stderr = stderr_callback,
        })
    vim.fn.jobwait({job})

    return remote_files

end

local get_remote_file = function(path, store_dir, remote_info)
    remote_info = remote_info or get_remote_details(path)
    local remote_location = remote_info.remote_path
    local file_location = store_dir .. remote_info.path
    local local_location = file_location .. ".gz"
    local command = "ssh " .. remote_info.auth_uri .. " \"/bin/sh -c 'cat " .. remote_info.remote_path .. " | gzip -c'\" > " .. local_location
    notify("Connecting to host: " .. remote_info.host, log.levels.INFO)
    local read_command = 'gzip -d -c ' .. local_location
    notify("Pulling down file: " .. remote_info.path .. " and saving to " .. file_location, log.levels.INFO)
    local worked, exitcode, code = os.execute(command)
    code = code or ""
    if exitcode then
        notify("Error Retrieving Remote File: {ENM03} -- Failed to pull down " .. path .. "! Received exitcode: " .. exitcode .. "\n    Additional Details: " .. code, log.levels.ERROR)
    end
    return read_command
end

return {
    get_remote_details = get_remote_details,
    get_remote_file    = get_remote_file
}
