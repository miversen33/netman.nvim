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
    return remote_info
end

-- local get_remote_files = function(remote_info, path)
--     remote_info = remote_info or get_remote_details()
--     print(tprint(remote_info))
--     print("Path: " .. path)
--     if remote_info.path then
--         print("Remote Path: " .. remote_info.path)
--     end
--     path = path or remote_info.path
--     local remote_cmd = protocol_patterns[remote_info.protocol].cmd
--     local args = { "find " .. path }
--     -- .. " -maxdepth 2 -printf '%Y|%P\\n' 2>/dev/null"}
--     if remote_info.user then
--         table.insert(args, 1, remote_info.user .. "@" .. remote_info.host)
--     else
--         table.insert(args, 1, remote_info.host)
--     end
--     local a = ""
--     for _, arg in pairs(args) do
--         a = a .. " " .. arg
--     end
--     local job = sys:new({
--         command = remote_cmd,
--         args = args
--     })
--     job:start()
--     job:join()
--     local results = job:result()
--     local files_metadata = {}
--     for _, file in pairs(results) do
--         local file_name, type, parent, _file, file_metadata
--         file_metadata = {
--             uri     = nil,
--             display = nil,
--             type    = nil
--         }
--
--         local is_dir_pattern = "^d|"
--         local is_file_pattern = "^f|"
--         local is_link_pattern = "^N|"
--         local parent_dir_pattern = "(/.*)|"
--
--         if file:find(is_file_pattern) then
--             type = "file"
--             file = file:gsub(is_file_pattern, "")
--         elseif file:find(is_dir_pattern) then
--             type = "dir"
--             file = file:gsub(is_dir_pattern, "")
--         elseif file:find(is_link_pattern) then
--             type = "link"
--             file = file:gsub(is_link_pattern, "")
--         else
--             type = "unk"
--         end
--
--         _, _, parent = file:find(parent_dir_pattern)
--         if parent then
--             file = file:gsub(parent_dir_pattern, "")
--         else
--             parent = ""
--         end
--         file_name = file
--         file_metadata.display = file_name
--         file_metadata.type    = type
--         file_metadata.uri     = remote_info.uri .. file_name
--         if files_metadata[parent] == nil then
--             files_metadata[parent] = {}
--         end
--         table.insert(files_metadata[parent], file_metadata)
--     end
--     -- Parse results and return them in a table with _some_ metadata about each entry. Consider the following template
--     -- {
--     --    short    = "$SHORT_FORM_PATH_NAME",
--     --    full     = "$LONG_FORM_PATH_NAME",
--     --    type     = "dir/file/link"
--     -- }
--     print(tprint(files_metadata))
--     return files_metadata
-- end

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
    return file_location, read_command
end

return {
    get_remote_details = get_remote_details,
    get_remote_file    = get_remote_file
}
