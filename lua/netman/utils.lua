local _notify = vim.notify
local level_table = {
    'TRACE',
    'DEBUG',
    'INFO',
    'WARN',
    'ERROR'
}

local _level_threshold = 3
local _is_setup = false

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
    local log_message = '[' .. timestamp .. '] [Level:' .. level .. ']'
    if level:len() == 4 then
        log_message = log_message .. ' '
    end
    log_message = log_message .. ' Netman'
    log_message = log_message .. ' -- ' .. message
    if log_message:match("[^A-Za-z0-9_/:=-]") then
        log_message = log_message:gsub("'", "\\'")
    end
    os.execute('echo "' .. log_message .. '" >> ' .. log_path)
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
    notify("Command: " .. command, vim.log.levels.DEBUG, true)
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
    if lock_info then
        notify("Found existing lock info for file --> " .. lock_info, vim.log.level.INFO, true)
        local lock_buffer, lock_pid = lock_info:match('^(%d+):(%d+)$')
        notify("Unable to lock file: " .. file_name .. " to buffer " .. buffer .. " for pid -1. File is already locked to pid: " .. lock_pid .. ' for buffer: ' .. lock_buffer, vim.log.levels.ERROR)
        return false
    end
    local current_pid = vim.fn.getpid()
    os.execute('echo "' .. buffer .. ':' .. current_pid .. '" > ' .. locks_dir .. file_name)
    return true
end

local unlock_file = function(file_name)
    if not is_file_locked(file_name) then
        return
    end
    os.execute('rm ' .. locks_dir .. file_name)
end

local adjust_log_level = function(new_level_threshold)
    _level_threshold = new_level_threshold
end

return {
    notify           = notify,
    setup            = setup,
    adjust_log_level = adjust_log_level
}
