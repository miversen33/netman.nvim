--- TODO: (Mike): God help me, this needs a refactor badly

local netman_options = require("netman.options")

local mkdir   = vim.fn.mkdir

vim.g.netman_log_level = vim.g.netman_log_level or 3
local _is_setup = false
local cache_dir = vim.fn.stdpath('cache') .. '/netman/'
local files_dir = cache_dir .. 'remote_files/'
local data_dir  = vim.fn.stdpath('data')  .. '/netman/'
local session_id = ''
local validate_log_pattern = '^%[%d+-%d+-%d+%s%d+:%d+:%d+%]%s%[SID:%s(%a+)%].'
local shell_escape_pattern = "([\\(%s@!\"\'\\)])"
local log_timestamp_format = '%Y-%m-%d %H:%M:%S'
local log_file = nil
local delay_ui_elements = true

local log = {}
local notify = {}
local _delay_buffer = {}
local log_level_map = {
    ERROR = 4,
    WARN = 3,
    INFO = 2,
    DEBUG = 1,
    TRACE = 0
}

log.levels = vim.deepcopy(vim.log.levels)
notify.levels = vim.deepcopy(log.levels)

local format_func = function(arg) return vim.inspect(arg, {newline='\n'}) end

local end_delay = function()
    if not delay_ui_elements then return end
    delay_ui_elements = false
    for _, _delay_details in ipairs(_delay_buffer) do
        if _delay_details._type == 'notify' then
            vim.api.nvim_notify(_delay_details.params.message, _delay_details.params.level, _delay_details.params.opts)
        elseif _delay_details._type == 'select' then
            vim.ui.select(_delay_details.params.items, _delay_details.params.opts, _delay_details.params.on_choice)
        elseif _delay_details._type == 'input' then
            vim.ui.input(_delay_details.params.params.options, _delay_details.params.on_confirm)
        end
    end

    _delay_buffer = {}
end

local get_input = function(options, on_confirm)
    if delay_ui_elements then
        table.insert(_delay_buffer, {_type = "input", params = {options = options, on_confirm = on_confirm}})
        return
    end
    vim.ui.input(options, on_confirm)
end

local get_select = function(items, opts, on_choice)
    if delay_ui_elements then
        table.insert(_delay_buffer, {_type = "select", params = {items = items, opts = opts, on_choice = on_choice}})
        return
    end
    vim.ui.select(items, opts, on_choice)
end

local generate_session_log = function(output_path, logs)
    logs = logs or {}
    output_path = vim.fn.resolve(vim.fn.expand(output_path))
    local log_path = data_dir .. "logs.txt"
    local line = ''
    local pulled_sid = ''
    local keep_running = true
    local log_file = io.input(log_path)
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
    io.close(log_file)
    local message = "Saving Logs"
    vim.api.nvim_notify(message, log_level_map.INFO, {})
    table.insert(logs, line)
    vim.fn.jobwait({vim.fn.jobstart('touch ' .. output_path)})
    vim.fn.writefile(logs, output_path)
    vim.api.nvim_notify("Saved logs to " .. output_path, 2, {})
    return logs
end

local generate_string = function(string_length)
    local return_string = ""
    for _ = 1, string_length do
        return_string = return_string .. string.char(math.random(97,122))
    end
    return return_string
end

local is_process_alive = function(pid)
    -- TODO(Mike): Convert this to using execute_shell_command
    local alive = true
    local stdout_callback = function(job, output)
        for _, line in pairs(output) do
            if not alive then return end
            if line and not line:match('^(%s*)$') then
                alive = false
            end
        end
    end
    vim.fn.jobwait({
        vim.fn.jobstart(
            'kill -0 '.. pid,
            {
                on_stdout = stdout_callback,
                on_stderr = stdout_callback
            }
        )
    })
    return alive
end

local setup = function(level_threshold)
    if _is_setup then
        return
    end
    math.randomseed(os.time()) -- seeding for random strings
    mkdir(cache_dir, 'p') -- Creating the cache dir
    mkdir(data_dir,  'p') -- Creating the data dir
    mkdir(files_dir, 'p') -- Creating the temp files dir
    mkdir(locks_dir, 'p') -- Creating the locks files dir
    log_file = io.open(data_dir .. "logs.txt", "a+")
    session_id = generate_string(15)

    _is_setup = true
end

local escape_shell_command = function(command, escape_string)
    escape_string = escape_string or '\\'
    return command:gsub(shell_escape_pattern, escape_string .. '%1')
end

local run_shell_command = function(command, options)
    options = options or {}
    if options.SHELL_ESCAPE then
        command = escape_shell_command(command)
    end
    local stdout = {}
    local stderr = {}
    local command_options = {}
    local gather_stdout_output = function(output)
        for _, line in ipairs(output) do
            if line then
                if not
                    (
                        options[netman_options.utils.command.IGNORE_WHITESPACE_OUTPUT_LINES]
                        and line:match('^(%s*)$')
                    )
                    then table.insert(stdout, line)
                end
            end
        end
    end

    local gather_stderr_output = function(output)
        for _, line in ipairs(output) do
            if line then
                if not
                    (
                        options[netman_options.utils.command.IGNORE_WHITESPACE_ERROR_LINES]
                        and line:match('^(%s*)$')
                    )
                    then table.insert(stderr, line)
                end
            end
        end
    end


    vim.fn.jobwait({
        vim.fn.jobstart(
            command,
            {
                on_stdout = function(_, output) gather_stdout_output(output) end
                ,on_stderr = function(_, output) gather_stderr_output(output) end
            }
        )
    })
    if options[netman_options.utils.command.STDOUT_JOIN] then
        stdout = table.concat(stdout, options[netman_options.utils.command.STDOUT_JOIN])
    end
    if options[netman_options.utils.command.STDERR_JOIN] then
        stderr = table.concat(stderr, options[netman_options
        .utils.command.STDERR_JOIN])
    end
    return {stdout=stdout, stderr=stderr}
end

local _notify = function(message, level)
    if delay_ui_elements then
        table.insert(_delay_buffer, {_type = "notify", params = {message=message, level=level, opts = {}}})
        return
    end
    vim.api.nvim_notify(message, level, {})
end

local _log = function(level, do_notify, ...)
    -- Yoinked the concepts in here from https://github.com/neovim/neovim/blob/master/runtime/lua/vim/lsp/log.lua
    -- Thanks Neovim team <3
    local argc = select("#", ...)
    if argc == 0 then return true end

    local info = debug.getinfo(3, "Sl")
    local header = string.format('[%s] [SID: %s] [Level: %s] ', os.date(log_timestamp_format), session_id, level)
    if level:len() == 4 then
        header = header .. ' '
    end
    header = string.format(header .. ' -- %s:%s', info.short_src, info.currentline)
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
    log_file:write(table.concat(parts, '\t'), "\n")
    log_file:flush()
    if do_notify then
        _notify(table.concat(headerless_parts, '\t'), log_level_map[level])
    end
    if level == 'ERROR' then
        _notify(table.concat(headerless_parts, '\t'), 1)
        error(table.concat(headerless_parts, '\t'), 1)
    end
end

function copy_table(in_table, deep)
    deep = deep or false
    local _copy_table = {}
    if type(in_table) ~= 'table' then
        return in_table
    end
    for k, v in pairs(in_table) do
        if deep then
            _copy_table[k] = copy_table(v)
        else
            _copy_table[k] = v
        end
    end
    return _copy_table
end

do
    local initial_setup = false
    if not _is_setup then
        initial_setup = true
        setup()
    end

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
    if initial_setup then
        log.info("Generated Session ID: " .. session_id .. " for logging.")
    end
end

return {
    notify               = notify,
    log                  = log,
    generate_string      = generate_string,
    is_process_alive     = is_process_alive,
    cache_dir            = cache_dir,
    data_dir             = data_dir,
    files_dir            = files_dir,
    generate_session_log = generate_session_log,
    copy_table           = copy_table,
    run_shell_command    = run_shell_command,
    escape_shell_command = escape_shell_command,
    end_delay            = end_delay,
    get_input            = get_input,
    get_select           = get_select
}
