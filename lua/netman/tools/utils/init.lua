local compat = require("netman.tools.compat")

local M = {
    _inited = false,
    cache_dir = '',
    tmp_dir = nil,
    files_dir = '',
    data_dir = '',
    socket_dir = '',
    logs_dir = '',
    pid = nil,
    session_id = nil,
    os_sep = compat.sep,
    os = compat.os
    deep_copy = nil,
    deprecation_date = nil
}

local function create_dirs()
   -- TODO: Probably should figure out how to do this without need vim.fn
    M.cache_dir = string.format("%s%snetman%s", vim.fn.stdpath('cache'), M.os_sep, M.os_sep)
    M._remote_cache = M.cache_dir .. 'remote_files' .. M.os_sep
    M.files_dir = M._remote_cache .. M.pid .. M.os_sep
    M.data_dir  = string.format("%s%snetman%s", vim.fn.stdpath('data'), M.os_sep, M.os_sep)
    M.tmp_dir = M.cache_dir .. "tmp" .. M.os_sep
    M.socket_dir = M.tmp_dir .. M.os_sep
    M.logs_dir = M.data_dir .. 'logs' .. M.os_sep
    -- Iterate over each directory and ensure it exists
    for _, path in ipairs({M.cache_dir, M._remote_cache, M.files_dir, M.data_dir, M.tmp_dir, M.socket_dir, M.logs_dir}) do
        compat.mkdir(path, 'p')
    end
end

local function get_logger(target, opts)
    target = target or 'system'
    opts = opts or {}
    opts.session_id = M.session_id
    opts.name = target
    opts.logs_dir = opts.logs_dir or M.logs_dir
    opts.level = opts.level
    if not opts.level then
        -- Walking this a bit more than usual
        -- because vim.g doesn't exist in luv threads mode
        if vim and vim.g and vim.g.netman_log_level then
            opts.level = vim.g.netman_log_level
        else
            opts.level = 3
        end
    end
    return require("netman.tools.utils.logger").new(opts)
end


local function serialize_self()
    local handle = io.open(M.tmp_dir .. M.pid, 'w')
    assert(handle, "Unable to open netman utils cache")
    for _, item in ipairs({'cache_dir', 'tmp_dir', 'files_dir', 'socket_dir', 'data_dir', 'session_id', 'logs_dir'}) do
        assert(handle:write(string.format('%s=%s\n', item, M[item]))  , "Unable to write to netman utils cache")
    end
    assert(handle:flush(), "Unable to save netman utils cache")
    assert(handle:close(), "Unable to close netman utils cache")
end

local function load_self()
    local _file = string.format("%s%s", M.tmp_dir, M.pid)
    local handle = io.open(M.tmp_dir .. M.pid, 'r')
    -- Probably want to verify this?
    if not handle then return nil end
    for line in handle:lines() do
        local key, value = line:match('^([^=]+)=(.*)$')
        M[key] = value
    end
    assert(handle:close(), "Unable to close netman utils cache")
    return true
end

local function clear_orphans(include_self)
    local logger = M.get_system_logger()
    logger.info("Searching for Orphaned directories")

    local parent_dir_id = compat.uv.fs_scandir(M._remote_cache)
    local child = {}
    local children = {}
    while child do
        child = compat.uv.fs_scandir_next(parent_dir_id)
        if child and (child ~= M.pid or include_self) then table.insert(children, child) end
    end
    if include_self then
        logger.tracef("Cleaning up after ourself too! Pid: %s", M.pid)
    end
    logger.trace("Found the following children to clean up", children)
    -- Integer to string comparisons don't work here
    local our_pid = string.format("%s", M.pid)
    for _, child_id in ipairs(children) do
        logger.tracef("Checking if %s is alive", child_id)
        if not M.is_process_alive(child_id) or (include_self and child_id == our_pid) then
            local _dir = string.format("%s%s", M._remote_cache, child_id)
            if(child_id == our_pid) then
                logger.tracef("Removing Process Temporary Directory %s", _dir)
            else
                logger.tracef("Removing Orphaned Directory %s", _dir)
            end
            compat.delete(_dir, 'rf')
            -- Clearing out the child utils state if it exists too
            compat.delete(M.tmp_dir .. child_id, 'rf')
        end
    end
    logger.info("Orphaned directories cleared")
end

local function setup_exit_handler()
    M.get_system_logger().trace("Setting Exit Handler")
    vim.api.nvim_create_autocmd({'VimLeave'}, {
        pattern = { '*' },
        desc = "Netman Utils Cleanup Autocommand",
        callback = function()
            clear_orphans(true)
        end
    })
end

local function setup()
    -- Seeding the random module for strings
    math.randomseed(os.time())
    M.pid = compat.uv.getpid()
    create_dirs()
    if load_self() then
        -- cache file exists, read it in to get the location of stuff
        -- otherwise, hopefully vim.fn exists...
        M._inited = true
        return
    end
    M.session_id = M.generate_string(15)
    serialize_self()
    -- This can probably be done asynchronously
    clear_orphans()
    setup_exit_handler()
    if M.deprecation_date then
        M.branch_deprecated()
    end
    M._inited = true
end

function M.generate_string(length)
    length = length or 10
    local return_string = ""
    for _ = 1, length do
        return_string = return_string .. string.char(math.random(97,122))
    end
    return return_string
end

function M.get_system_logger()
    return get_logger()
end

function M.get_provider_logger()
    return get_logger('provider')
end

function M.get_consumer_logger()
    return get_logger('consumer')
end

function M.is_process_alive(pid)
    local command_flags = require("netman.tools.shell").CONSTANTS.FLAGS
    local command = {}
    local check_output = nil
    if M.os == 'windows' then
        command = {'wmic', 'process', 'where', string.format("ProcessID = %s", pid), 'get', 'processid'}
        check_output = function(output)
            local stdout = output.stdout
            local stderr = output.stderr
            local has_error = stderr and stderr:len() > 0
            if
                (stderr and stderr:len() > 0)
                or not stdout
                or stdout:match('No Instance') then
                return false
            end
            return true
        end
    else
        command = {'kill', '-0', pid}
        check_output = function(output)
            local stdout = output.stdout
            local stderr = output.stderr
            if stderr ~= '' or stdout ~= '' then
                return false
            end
            return true
        end
    end
    
    local command_options = {}
    command_options[command_flags.STDOUT_JOIN] = ''
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = require("netman.tools.shell"):new(command, command_options):run()
    return check_output(command_output)
end

function M.get_real_path(path)
    if not path then return '' end
    -- Should make this OS agnostic
    local _path = {}
    for node in path:gmatch(string.format('[^%s]+', M.os_sep)) do
        if node == '~' then
            node = compat.uv.os_homedir()
        end
        -- Stripping off leading `$`
        if node:match('^%$') then
            node = node:sub(2, -1)
        end
        local _ = compat.uv.os_getenv(node)
        table.insert(_path, _ or node)
    end
    local new_path = table.concat(_path, '/')
    if new_path:sub(1,1) ~= '/' then new_path = '/' .. new_path end
    return new_path
end

function M.branch_deprecated()
    M.get_system_logger().warnnf("This branch of Netman has been deprecated. It will be removed on the end of %s. Please consider moving back to Main or to one of the other dev branches.", M.deprecation_date)
end

function M.deep_copy(in_table)
    -- Yoinked from https://stackoverflow.com/a/640645/2104990
    local orig_type = type(in_table)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, in_table, nil do
            copy[M.deep_copy(orig_key)] = M.deep_copy(orig_value)
        end
        setmetatable(copy, M.deep_copy(getmetatable(in_table)))
    else -- number, string, boolean, etc
        copy = in_table
    end
    return copy
end

if not M._inited then
    setup()
end
return M
