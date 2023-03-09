local compat = require("netman.tools.compat")

--- Netman Logger
local CONSTANTS = {
    LEVELS = {
        CRITICAL = {
            map_level = 4,
            real_level = 0
        },
        ERROR = {
            map_level = 4,
            real_level = 1
        },
        WARN = {
            map_level = 3,
            real_level = 2
        },
        INFO = {
            map_level = 2,
            real_level = 3
        },
        DEBUG = {
            map_level = 1,
            real_level = 4
        },
        TRACE = {
            map_level = 0,
            real_level = 5
        },
        TRACE2 = {
            map_level = 0,
            real_level = 6
        },
        TRACE3 = {
            map_level = 0,
            real_level = 7
        }
    },
    LOG_TIMESTAMP_FORMAT = '%Y-%m-%d %H:%M:%S'
}

local DEFAULTS = {
    level = CONSTANTS.LEVELS.WARN.real_level,
    name = 'root',
    -- The maximium that is kept in the log queue internally
    -- This means the last 2000 logs are kept in memory regardless of level
    -- NOTE: This does _not_ affect the backing store, only the in memory store
    internal_limit = 2000,
}

-- store for loggers.
local _loggers = {}
-- Memory store for all logs in the current session
local _session_logs = {}

local M = {
    LEVELS = CONSTANTS.LEVELS,
}

--- Creates a new logging object to write logs to
--- Note, if we can find an exisiting logger with the same
--- name as was provided, we will return that instead of
--- making a new one
--- @param opts table
---     A table of options (I mean, what else did you expect here?)
---     Valid keys and their values
---     - only_opts boolean
---         Default: false
---         If provided, when we create the logger object, we will _only_ use the 
---         options table provided. This means that no defaults will be set. Not,
---         using this option means you may get errors if you omit any required options
---     - level integer
---         Default: 3
---         The log filter level. -1 means _all_ logs, 3 (in this case) is WARN, and thus anything below level "WARN" will
---         not be written to the log. Note, everything is saved to the in memory log.
---         Valid Levels are found in require("netman.tools.utils.logs").LEVELS
---         Note: levels correspond with their associated "log" function, as explained below
---     - stack_offset integer
---         Default: 3
---         The number of levels you wish to have "removed" from the stack when pulling
---         caller information. Don't change this unless you know what you're doing
---     - name string
---         Default: 'root'
---         The to assign to this logger. Note, we will also see if there is already logger matching
---         and if so, we will return it instead of making a new one
---     - session_id string (Required)
---         This must be provided, there is no default for it.
---         The session id the logger should be associated with.
---     - logs_dir string
---         Default: nil
---         If provided, the directory to write the log file to. Note, it must exist and be writable
---         Note: if this is not provided, logs will not be saved to disk
--- @return table
---     Returns a new logger object that will have the following methods associated with it
---     close()
---         Closes the logger and any file handles. Also removes the logger from memory
---         so a new logger can be created with the same name as this one
---     emit(log_level, session_id, message, opts)
---         Emits the log both interally and into the backing store provided
---         @param log_level string
---             The level to display the log at. Note, if you wish to "filter" the log
---             (IE only store locally), you can provide an option in @see opts
---         @param session_id string
---             The session id to associate with this log
---         @param message string
---             The message to emit
---         @param opts table
---             Various options that can be provided with the log
---             Valid keys and their meanings
---             - filtered boolean
---                 If provided, this indicates that the log is "filtered" out and should
---                 only be stored locally. Useful for not overflowing the backing store
---             - log_timestamp_format string
---                 The string to use to "format" the timestamp. For details, see
---                 https://www.lua.org/pil/22.1.html
---             - details table | string
---                 Any additional details you want to go in the log. Note, if its a table, we will
---                 "Pretty" it before dumping it into the log
---             - header_padding_count | int
---                 If provided, will add spaces up to the integer provided to the header before adding
---                 the message. Good for prettier logs
---             - notify | boolean
---                 If provided, we will emit (on the UI thread) a notification of the same log
---                 to the user
---             - dump_callstack | boolean
---                 If provided, we will dump the callstack (up 2 levels from this) immediatly following the log
---                 useful if you want certain log levels to auto dump the stack into the log
---     level(message, ...)
---         This isn't super clear, but I don't feel like writing the same doc over and over.
---         `level` can be any of the levels found in `require("netman.tools.utils.logger").LEVELS`
---         Note: there is a variation of this function called `leveln` which does the exact same thing
---         however it also raises a vim notification
---         @param message string
---             The string message you want to log
---         @param ... varags
---             n length whatever the hell you want. Can be strings, tables, objects, jesus, we can handle it all.
---         @example
---             debug("My message", {data="somedata", key="some key"})
---             error("My Error", {info = "error message?"})
---             trace3("My highly verbose message")
---             -- Example of notify version
---             debugn("My Notification")
---             infon("My Notification", {details = "with details!"})
---     levelf(preformatted_message, ...)
---         This isn't super clear, but I don't feel like writing the same doc over and over.
---         `level` can be any of the levels found in `require("netman.tools.utils.logger").LEVELS`
---         Note, this is meant to act as a sort of proxy for `string.format`. I just get annoyed
---         having to call that function all the time, so this basically wraps that
---         Note: there is a variation of this function called `levelnf` which does the exact same thing
---         however it also raises a vim notification
---         @param preformatted_message string
---             The preformatted string you want to log
---         @param ... varags
---             n length array of strings. This should operate the same as @see string.format
---         @example
---             debugf("My preformatted message containing: %s", "something really useful!")
---             criticalf("My preformatted critical error about %s", "Something catastrophic that happened!")
---             trace2f("Some generally %s info about %s", "useless", "the flying spaghetti monster")
---             -- Example of notify version
---             debugnf("My formatted %s", "notification")
---             infonf("My %s notification to be raised to the %s", "info level", "user")
M.new = function(opts)
    -- Copying options over
    opts = opts or {}
    if not opts.only_opts then
        for key, value in pairs(DEFAULTS) do
            if opts[key] == nil then
                opts[key] = value
            end
        end
    else
        -- Doing some assertions since the user said not to
        -- mix defaults with their logic
        assert(opts.name, "No name provided for logger!")
    end
    assert(opts.session_id, "No session id provided for logger!")
    if _loggers[opts.name] then
        -- Found an exising logger with this name
        return _loggers[opts.name]
    end
    local log_file_handle = nil
    local log_file_path = nil
    if opts.logs_dir then
        log_file_path = opts.logs_dir .. '/' .. opts.name
        log_file_handle = io.open(log_file_path, 'a+')
        assert(log_file_handle, string.format("Unable to open log file %s!", log_file_path))
    else
        print(string.format("Creating logger %s without a backing store. Ye be warned", opts.name))
    end

    local logger = {
        _log_file_handle = log_file_handle,
        name = opts.name,
        -- If any number < 0 is provided, we will write _all_ logs
        filter_level = opts.level or 3,
        id = opts.session_id,
        offset = opts.offset or 3
    }

    --- Closes the logger, removes the name reference and closes the file handles
    logger.close = function()
        if logger._log_file_handle and log_file_path then
            assert(logger._log_file_handle:flush(), string.format("Unable Write log file %s", log_file_path))
            assert(logger._log_file_handle:close(), string.format("Unable to close log file %s", log_file_path))
        end
        _loggers[logger.name] = nil
    end
    logger.emit = function(log_level, session_id, message, _opts)
        local timestamp = os.date(_opts.log_timestamp_format or CONSTANTS.LOG_TIMESTAMP_FORMAT)
        local header_padding = ''
        local stack_info = debug.getinfo(logger.offset, 'Sln')
        message = message or ''
        if _opts.header_padding_count then
            -- Some quick garbage to generate header padding
            for _=0, _opts.header_padding_count do header_padding = header_padding .. ' ' end
        end
        local header = string.format(
            '[%s] [SID: %s] [Logger: %s] [Level: %s]%s -- %s:%s:%s',
            timestamp, session_id, logger.name, log_level, header_padding,
            stack_info.short_src, stack_info.name, stack_info.currentline
        )
        if type(message) == 'table' then message = vim.inspect(message, {newline = '\n'}) end
        local log_parts = { message }
        if _opts.details then
            for _, detail in ipairs(_opts.details) do
                if type(detail) == 'table' then
                    table.insert(log_parts, vim.inspect(detail, {newline = '\n'}))
                else
                    table.insert(log_parts, string.format('%s', detail))
                end
            end
        end
        log_parts = { table.concat(log_parts, ' ') }
        if _opts.dump_callstack then
            table.insert(log_parts, debug.traceback("", 3))
        end
        if not _session_logs[session_id] then _session_logs[session_id] = {} end
        local _generated_log = table.concat(log_parts, '\t')
        table.insert(_session_logs[session_id], header .. '\t' .. _generated_log)
        while #_session_logs[session_id] > opts.internal_limit do
            -- Keep popping the head off the internal log queue until we at the limit
            table.remove(_session_logs[session_id], 1)
        end
        if not _opts.filtered and logger._log_file_handle then
            logger._log_file_handle:write(header .. '\t' .. _generated_log .. '\n')
            -- I wonder if we actually need to flush??
            logger._log_file_handle:flush()
        end
        -- Little bit of jank to maybe ensure that we can notify even if we
        -- are running in a different thread
        if _opts.notify then
            -- It is maybe possible that we dont need schedule since new_async is
            -- a link to the main ui thread?
            -- TODO: It seems that new_async does not work inside new_work...?
            local _ = nil
            _= vim.loop.new_async(function()
                vim.schedule(function()
                    -- The level here is all sorts of wrong, it seems that vim counts
                    -- levels backwards (so error is 0, debug is 4, etc)
                    -- And I don't really feel like dealing with it right now
                    -- TODO: Mike deal with it eventually
                    vim.api.nvim_notify(_generated_log, M.LEVELS[log_level].map_level, {})
                end)
                _:close()
            end)
            _:send()
        end
    end

    local _max_level_string_length = 0
    -- Ya we are doing a double loop, deal with it
    for level, _ in pairs(CONSTANTS.LEVELS) do
        if level:len() > _max_level_string_length then _max_level_string_length = level:len() end
    end
    for string_level, level_details in pairs(CONSTANTS.LEVELS) do
        logger[string_level:lower()] = function(message, ...)
            local do_notify = level_details.real_level == 0
            local do_callstack_dump = level_details.real_level <= 1
            local filtered = logger.filter_level >= 0 and level_details.real_level > logger.filter_level
            logger.emit(
                string_level,
                logger.id,
                message,
                {
                    details = {...},
                    header_padding_count = (_max_level_string_length - string_level:len() - 1),
                    notify = do_notify,
                    dump_callstack = do_callstack_dump,
                    filtered = filtered
                }
            )
        end
        logger[string.format('%sf', string_level:lower())] = function(preformatted_message, ...)
            -- local argc = select('#', ...)
            local data = {}
            local message = ''
            for _, item in ipairs({...}) do
                table.insert(data, item)
            end
            if #data > 0 then
                message = string.format(preformatted_message, compat.unpack(data))
            end
            local do_notify = level_details.real_level == 0
            local do_callstack_dump = level_details.real_level <= 1
            local filtered = logger.filter_level >= 0 and level_details.real_level > logger.filter_level
            logger.emit(
                string_level,
                logger.id,
                message,
                {
                    header_padding_count = _max_level_string_length - string_level:len(),
                    notify = do_notify,
                    dump_callstack = do_callstack_dump,
                    filtered = filtered
                }
            )
        end
        logger[string.format("%sn", string_level:lower())] = function(message, ...)
            local do_callstack_dump = level_details.real_level <= 1
            local filtered = logger.filter_level >= 0 and level_details.real_level > logger.filter_level
            logger.emit(
                string_level,
                logger.id,
                message,
                {
                    details = {...},
                    header_padding_count = _max_level_string_length - string_level:len(),
                    notify = true,
                    dump_callstack = do_callstack_dump,
                    filtered = filtered
                }
            )
        end
        logger[string.format('%snf', string_level:lower())] = function(preformatted_message, ...)
            local argc = select('#', ...)
            local data = {}
            local message = ''
            for i = 1, argc do
                table.insert(data, select(i, ...))
            end
            if #data > 0 then
                message = string.format(preformatted_message, compat.unpack(data))
            end
            local do_callstack_dump = level_details.real_level <= 1
            local filtered = logger.filter_level >= 0 and level_details.real_level > logger.filter_level
            logger.emit(
                string_level,
                logger.id,
                message,
                {
                    header_padding_count = _max_level_string_length - string_level:len(),
                    notify = true,
                    dump_callstack = do_callstack_dump,
                    filtered = filtered
                }
            )
        end
    end

    _loggers[opts.name] = logger
    return logger
end

--- Returns the logs for a session id
--- @param session_id string
---     The id of the session. Utils should have this
---     Note: if not provided, we will return _all_ logs
--- @return table
---     Returns a 1 or 2 dimensional table of the logs.
---     It will be a 1 dimensional table if a valid session id is provided (meaning
---     that the table will basically just be an array of logs), and a 2 dimensional table
---     if an invalid session_id was provided (as the keys will be the session_ids available)
--- Note: This does _not_ read from the filestore
M.get_session_logs = function(session_id)
    return _session_logs[session_id] or _session_logs
end

return M
