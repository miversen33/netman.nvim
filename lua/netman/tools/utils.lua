local netman_options = require("netman.tools.options")
local explorer_status = require('netman.tools.options').explorer.EXPLORER_STATUS
local command_flags = require("netman.tools.options").utils.command
local unpack = require("netman.tools.compat").unpack

vim.g.netman_log_level         = vim.g.netman_log_level or 3

local mkdir                = vim.fn.mkdir
local _is_setup            = false
local cache_dir            = vim.fn.stdpath('cache') .. '/netman/'
local files_dir            = cache_dir .. 'remote_files/'
local data_dir             = vim.fn.stdpath('data')  .. '/netman/'
local socket_dir           = '/tmp/netman/'
local session_id           = ''
local validate_log_pattern = '^%[%d+-%d+-%d+%s%d+:%d+:%d+%]%s%[SID:%s(%a+)%].'
local shell_escape_pattern = [[([%s^&*()%]="'+.|,<>?%[{}%\])]]
local log_timestamp_format = '%Y-%m-%d %H:%M:%S'
local package_name_escape  = "([\\(%s@!\"\'\\)-.])"
local log_file             = nil
local log                  = {}
local notify               = {}
local pid                  = vim.fn.getpid()
local netman_config_path   = vim.fn.stdpath('data') .. '/netman/providers.json'
local log_level_map        = {
    ERROR = 4,
    WARN = 3,
    INFO = 2,
    DEBUG = 1,
    TRACE = 0
}

log.levels = vim.deepcopy(vim.log.levels)
notify.levels = vim.deepcopy(log.levels)

local escape_shell_command = function(command, escape_string)
    escape_string = escape_string or '\\'
    return command:gsub(shell_escape_pattern, escape_string .. '%1')
end

local format_func = function(arg) return vim.inspect(arg, {newline='\n'}) end
local generate_session_log = function(output_path, logs)
    logs = logs or {}
    if output_path ~= 'memory' then
        output_path = vim.fn.resolve(vim.fn.expand(output_path))
    end
    local log_path = data_dir .. "logs.txt"
    local line = ''
    local pulled_sid = ''
    local keep_running = true
    -- Seems wrong
    local _log_file = io.input(log_path)
    vim.api.nvim_notify("Gathering Logs...", log_level_map.INFO, {})
    while keep_running do
        line = io.read('*line')
        if not line then
            keep_running = false
        else
           pulled_sid = line:match(validate_log_pattern)
            if pulled_sid == session_id then
                table.insert(logs, line)
            end
        end
    end
    io.close(_log_file)
    local message = ''
    if output_path ~= 'memory' then message = "Saving Logs" else message = "Generating Logs" end
    vim.api.nvim_notify(message, log_level_map.INFO, {})
    table.insert(logs, line)
    if output_path ~= 'memory' then
        vim.fn.jobwait({vim.fn.jobstart('touch ' .. output_path)})
        -- Consider _not_ doing this?
        local outfile = io.output(output_path)
        outfile:write(table.concat(logs, '\n'))
        outfile:close()
        vim.api.nvim_notify("Saved logs to " .. output_path, 2, {})
    end
    return logs
end

local generate_string = function(string_length)
    string_length = string_length or 10
    local return_string = ""
    for _ = 1, string_length do
        -- use vim.loop.random since its already here?
        return_string = return_string .. string.char(math.random(97,122))
    end
    return return_string
end

local is_process_alive = function(pid)
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

local dump_callstack = function(callstack_offset)
    callstack_offset = callstack_offset or 2
    log_file:write(debug.traceback("", callstack_offset), "\n")
    log_file:flush()
end

local get_calling_source = function(source_offset)
    source_offset = source_offset or 0
    local offset = 3 + source_offset
    return debug.getinfo(offset, 'S').source
end

local _log = function(level, do_notify, ...)
    -- Yoinked the concepts in here from https://github.com/neovim/neovim/blob/master/runtime/lua/vim/lsp/log.lua
    -- Thanks Neovim team <3
    local argc = select("#", ...)
    if argc == 0 then return true end

    local info = debug.getinfo(3, "Sln")
    local header = string.format('[%s] [SID: %s] [Level: %s] ', os.date(log_timestamp_format), session_id, level)
    if level:len() == 4 then
        header = header .. ' '
    end
    header = string.format(header .. ' -- %s:%s:%s', info.short_src, info.name, info.currentline)
    local parts = { header }
    local headerless_parts = {}
    for i = 1, argc do
        local arg = select(i, ...)
        if arg == nil then
            table.insert(parts, "nil")
            table.insert(headerless_parts, "nil")
        else
            table.insert(parts, format_func(arg))
            table.insert(headerless_parts, format_func(arg))
        end
    end
    if level == 'ERROR' then
        table.insert(parts, debug.traceback("", 3))
    end
    log_file:write(table.concat(parts, '\t'), "\n")
    log_file:flush()
    if do_notify or level == 'ERROR' then
        vim.api.nvim_notify(table.concat(headerless_parts, '\t'), log_level_map[level], {})
    end
end

local setup = function()
    if _is_setup then
        return
    end
    -- Making sure these exist as we do filesystem operations on them. IE, they
    -- MUST exist before we do stuff with them
    mkdir(cache_dir, 'p') -- Creating the cache dir
    mkdir(files_dir, 'p') -- Creating the temp files dir
    local parent_dir = files_dir
    local _parent_dir_id = vim.loop.fs_scandir(parent_dir)
    local child = {}
    local children = {}
    while child do
        child = vim.loop.fs_scandir_next(_parent_dir_id)
        if child then table.insert(children, child) end
    end
    files_dir = files_dir .. pid .. '/'
    math.randomseed(os.time()) -- seeding for random strings
    session_id = generate_string(15)
    for level, levelnr in pairs(log.levels) do
        log[level] = levelnr
        notify[level] = levelnr

        log[level:lower()] = function(...)
            if levelnr < vim.g.netman_log_level then return end
            _log(level, false, ...)
        end
        notify[level:lower()] = function(...)
            if levelnr < vim.g.netman_log_level then return end
            _log(level, true, ...)
        end
    end
    mkdir(data_dir,  'p') -- Creating the data dir
    mkdir(files_dir, 'p') -- Creating the temp files dir
    mkdir(socket_dir, 'p') -- Creating the socket dir
    local _ = io.open(netman_config_path, 'a+')
    if not _ then
        error(string.format("Unable to open netman configuration: %s", netman_config_path))
    end
    _:close()
    log_file = io.open(data_dir .. "logs.txt", "a+")
    log.info("--------------------Netman Utils initialization started!---------------------")
    log.info("Verifying Netman directories exist", {cache_dir=cache_dir, data_dir=data_dir, files_dir=files_dir})
    log.info("Generated Session ID: " .. session_id .. " for logging.")
    for _, child in ipairs(children) do
        log.trace(string.format("Checking if %s is alive", child))
        if not is_process_alive(child) then
            log.trace("Removing Orphaned Files Directory " .. parent_dir .. tostring(child))
            vim.fn.delete(parent_dir .. child, 'rf')
        end
    end
    log.info("--------------------Netman Utils initialization complete!---------------------")
    _is_setup = true
end

do
    if not _is_setup then
        setup()
    end
end

return {
    notify               = notify,
    log                  = log,
    cache_dir            = cache_dir,
    data_dir             = data_dir,
    files_dir            = files_dir,
    socket_dir           = socket_dir,
    package_name_escape  = package_name_escape,
    generate_string      = generate_string,
    is_process_alive     = is_process_alive,
    generate_session_log = generate_session_log,
    escape_shell_command = escape_shell_command,
    dump_callstack       = dump_callstack,
    get_calling_source   = get_calling_source,
    netman_config_path   = netman_config_path,
}
