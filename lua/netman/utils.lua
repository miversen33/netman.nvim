local mkdir   = vim.fn.mkdir

local level_table = {
    'TRACE',
    'DEBUG',
    'INFO',
    'WARN',
    'ERROR'
}

local _level_threshold = 3
local _is_setup = false
local cache_dir = vim.fn.stdpath('cache') .. '/netman/'
local files_dir = cache_dir .. 'remote_files/'
local locks_dir = cache_dir .. 'lock_files/'
local data_dir  = vim.fn.stdpath('data')  .. '/netman/'
local session_id = ''
local validate_log_pattern = '^%[%d+-%d+-%d+%s%d+:%d+:%d+%]%s%[SID:%s(%a+)%].'

local notify = function(message, level, file_only, log_path)
    level = level or 0
    if level < _level_threshold then
        return
    end
    file_only = file_only or false
    level = level_table[level + 1]
    log_path = log_path or data_dir .. "logs.txt"
    if not file_only then
        vim.notify(message, level)
    end
    local timestamp = os.date('%Y-%m-%d %H:%M:%S')
    local log_message = '[' .. timestamp .. '] [SID: ' .. session_id .. '] [Level:' .. level .. ']'
    if level:len() == 4 then
        log_message = log_message .. ' '
    end
    log_message = log_message .. ' Netman'
    log_message = log_message .. ' -- ' .. message
    vim.fn.writefile({log_message}, log_path, 'a')
end

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
    for index = 1, string_length do
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
    notify('Checking if file: ' .. file_name .. ' is locked', vim.log.levels.DEBUG, true)
    notify("Check Lock Command: " .. command, vim.log.levels.DEBUG, true)
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
                notify("Received Lock file check error: " .. line, vim.log.levels.INFO, true)
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
            notify("Clearing out stale lockfile: " .. file_name, vim.log.levels.INFO, true)
            os.execute('rm ' .. locks_dir .. file_name)
        end
    end
    return lock_info
end

local lock_file = function(file_name, buffer)
    local lock_info = is_file_locked(file_name)
    local current_pid = vim.fn.getpid()
    if lock_info then
        notify("Found existing lock info for file --> " .. lock_info, vim.log.levels.INFO, true)
        local lock_buffer, lock_pid = lock_info:match('^(%d+):(%d+)$')
        notify("Unable to lock file: " .. file_name .. " to buffer " .. buffer .. " for pid " .. current_pid .. ". File is already locked to pid: " .. lock_pid .. ' for buffer: ' .. lock_buffer, vim.log.levels.ERROR)
        return false
    end
    os.execute('echo "' .. buffer .. ':' .. current_pid .. '" > ' .. locks_dir .. file_name)
    return true
end

local unlock_file = function(file_name)
    if not is_file_locked(file_name) then
        return
    end
    notify("Removing lock file for " .. file_name, vim.log.levels.INFO, true)
    os.execute('rm ' .. locks_dir .. file_name)
    notify("Removing cached file for " .. file_name, vim.log.levels.INFO, true)
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
    session_id = generate_string(15)
    notify("Generated Session ID: " .. session_id .. " for logging.", vim.log.levels.INFO, true)

    _is_setup = true
    if _level_threshold == 0 then
        notify("Netman Running in DEBUG mode!", vim.log.levels.INFO, true)
    end
end

return {
    notify               = notify,
    setup                = setup,
    adjust_log_level     = adjust_log_level,
    generate_string      = generate_string,
    lock_file            = lock_file,
    unlock_file          = unlock_file,
    is_file_locked       = is_file_locked,
    cache_dir            = cache_dir,
    data_dir             = data_dir,
    files_dir            = files_dir,
    generate_session_log = generate_session_log
}
