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

local setup = function(level_threshold)
    if _is_setup then
        return
    end
    _level_threshold = level_threshold or _level_threshold
    _is_setup = true
end

local adjust_log_level = function(new_level_threshold)
    _level_threshold = new_level_threshold
end

local notify = function(message, level, log_path)
    level = level or 0
    if level < _level_threshold then
        return
    end
    level = level_table[level + 1]
    log_path = log_path or "$HOME/.cache/nvim/netman/logs.txt"
    vim.notify(message, level)
    local timestamp = os.date('%Y-%m-%d %H:%M:%S')
    local log_message = '[' .. timestamp .. '] [Level:' .. level .. '] -- ' .. message
    os.execute('echo "' .. log_message .. '" >> ' .. log_path)
end

return {
    notify           = notify,
    setup            = setup,
    adjust_log_level = adjust_log_level
}
