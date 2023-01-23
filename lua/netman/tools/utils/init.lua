local compat = require("netman.tools.compat")

local M = {
    _inited = false,
    cache_dir = '',
    tmp_dir = '',
    files_dir = '',
    data_dir = '',
    socket_dir = '',
    logs_dir = '',
    pid = nil,
    session_id = nil
}

local function create_dirs()
   -- TODO: Probably should figure out how to do this without need vim.fn
    M.cache_dir = vim.fn.stdpath('cache') .. '/netman/'
    M._remote_cache = M.cache_dir .. 'remote_files/'
    M.files_dir = M._remote_cache .. M.pid .. '/'
    M.data_dir  = vim.fn.stdpath('data')  .. '/netman/'
    M.tmp_dir   = '/tmp/netman/'
    M.socket_dir = M.tmp_dir
    M.logs_dir = M.data_dir .. 'logs'
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
    opts.level = opts.level or vim.g.netman_log_level or 3
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
    local handle = io.open(M.tmp_dir .. M.pid, 'r')
    -- Probably want to verify this?
    if not handle then return nil end
    local cache_contents = handle:read()
    assert(cache_contents, "Unable to read netman utils cache")
    for line in cache_contents:lines() do
        local key, value = line:match('^([^=]+)=(.*)$')
        M[key] = value
    end
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
    if load_self() then
        -- cache file exists, read it in to get the location of stuff
        -- otherwise, hopefully vim.fn exists...
        M._inited = true
        return
    end
    M.session_id = M.generate_string(15)
    create_dirs()
    serialize_self()
    -- This can probably be done asynchronously
    clear_orphans()
    setup_exit_handler()
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
    local command = {'kill', '-0', pid}

    local command_options = {}
    command_options[command_flags.STDOUT_JOIN] = ''
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = require("netman.tools.shell"):new(command, command_options):run()
    if command_output.stderr ~= '' or command_output.stdout ~= '' then
        return false
    end
    return true
end

if not M._inited then
    setup()
end
return M
