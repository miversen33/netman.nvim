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

return {
    notify           = notify,
    setup            = setup,
    adjust_log_level = adjust_log_level
}
