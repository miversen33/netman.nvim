local mkdir   = vim.fn.mkdir

local _level_threshold = 3
local _is_setup = false
local cache_dir = vim.fn.stdpath('cache') .. '/netman/'
local files_dir = cache_dir .. 'remote_files/'
local locks_dir = cache_dir .. 'lock_files/'
local data_dir  = vim.fn.stdpath('data')  .. '/netman/'
local session_id = ''
local validate_log_pattern = '^%[%d+-%d+-%d+%s%d+:%d+:%d+%]%s%[SID:%s(%a+)%].'
local log_timestamp_format = '%Y-%m-%d %H:%M:%S'
local log_file = nil

local log = {}
local notify = {}

log.levels = vim.deepcopy(vim.log.levels)
notify.levels = vim.deepcopy(log.levels)

local format_func = function(arg) return vim.inspect(arg, {newline='\n'}) end

local generate_session_log = function(output_path, logs)
    logs = logs or {}
    output_path = vim.fn.resolve(vim.fn.expand(output_path))
    local log_path = data_dir .. "logs.txt"
    local line = ''
    local pulled_sid = ''
    local keep_running = true
    local log_file = io.input(log_path)
    notify("Gathering Logs...", vim.log.levels.INFO)
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
    notify(message, vim.log.levels.INFO)
    table.insert(logs, line)
    vim.fn.jobwait({vim.fn.jobstart('touch ' .. output_path)})
    vim.fn.writefile(logs, output_path)
    notify("Saved logs to " .. output_path)
end

local generate_string = function(string_length)
    local return_string = ""
    for _ = 1, string_length do
        return_string = return_string .. string.char(math.random(97,122))
    end
    return return_string
end

local _verify_lock = function(pid)
    local valid_lock = true
    local stdout_callback = function(job, output)
        for _, line in pairs(output) do
            if not valid_lock then return end
            if line and not line:match('^(%s*)$') then
                valid_lock = false
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
    return valid_lock
end

local is_file_locked = function(file_name)
    local command = 'cat ' .. locks_dir .. file_name
    log.debug('Checking if file: ' .. file_name .. ' is locked')
    log.debug("Check Lock Command: " .. command)
    local lock_info = ''
    local stdout_callback = function(job, output)
        if not lock_info or lock_info:len() > 0 then return end
        for _, line in pairs(output) do
            if line and not line:match('^(%s*)$') then
                lock_info = line
            end
        end
    end
    local stderr_callback = function(job, output)
        if not lock_info then return end
        for _, line in pairs(output) do
            if line and not line:match('^(%s*)$') then
                log.info("Received Lock file check error: " .. line)
                lock_info = nil
                return
            end
        end
    end
    vim.fn.jobwait({
        vim.fn.jobstart(
            command,
            {
                on_stdout = stdout_callback,
                on_stderr = stderr_callback
            }
        )
    })
    if lock_info == '' then
        lock_info = nil
    elseif lock_info then
        local _, lock_pid = lock_info:match('^(%d+):(%d+)$')
        if not _verify_lock(lock_pid) then
            lock_info = nil
            log.info("Clearing out stale lockfile: " .. file_name)
            os.execute('rm ' .. locks_dir .. file_name)
        end
    end
    return lock_info
end

local lock_file = function(file_name, buffer)
    local lock_info = is_file_locked(file_name)
    local current_pid = vim.fn.getpid()
    if lock_info then
        log.info("Found existing lock info for file --> " .. lock_info)
        local lock_buffer, lock_pid = lock_info:match('^(%d+):(%d+)$')
        notify.error("Unable to lock file: " .. file_name .. " to buffer " .. buffer .. " for pid " .. current_pid .. ". File is already locked to pid: " .. lock_pid .. ' for buffer: ' .. lock_buffer)
        return false
    end
    os.execute('echo "' .. buffer .. ':' .. current_pid .. '" > ' .. locks_dir .. file_name)
    return true
end

local unlock_file = function(file_name)
    if not is_file_locked(file_name) then
        return
    end
    log.info("Removing lock file for " .. file_name)
    os.execute('rm ' .. locks_dir .. file_name)
    log.info("Removing cached file for " .. file_name)
    os.execute('rm ' .. files_dir .. file_name)
end

local adjust_log_level = function(new_level_threshold)
    _level_threshold = new_level_threshold
end

local setup = function(level_threshold)
    if _is_setup then
        return
    end
    _level_threshold = level_threshold or _level_threshold -- setting default logging level
    math.randomseed(os.time()) -- seeding for random strings
    mkdir(cache_dir, 'p') -- Creating the cache dir
    mkdir(data_dir,  'p') -- Creating the data dir
    mkdir(files_dir, 'p') -- Creating the temp files dir
    mkdir(locks_dir, 'p') -- Creating the locks files dir
    log_file = io.open(data_dir .. "logs.txt", "a+")
    session_id = generate_string(15)

    _is_setup = true
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
        vim.notify(table.concat(headerless_parts, '\t'), level)
    end
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
            if levelnr < _level_threshold then return end
            _log(level, false, ...)
        end
        notify[level:lower()] = function(...)
            if levelnr < _level_threshold then return end
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
    adjust_log_level     = adjust_log_level,
    generate_string      = generate_string,
    lock_file            = lock_file,
    unlock_file          = unlock_file,
    is_file_locked       = is_file_locked,
    cache_dir            = cache_dir,
    data_dir             = data_dir,
    files_dir            = files_dir,
    generate_session_log = generate_session_log,
}
