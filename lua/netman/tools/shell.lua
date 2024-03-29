-- Heavily inspired by
-- https://github.com/nvim-lua/plenary.nvim/blob/master/lua/plenary/job.lua
-- This is a stripped down version of plenary's "job" api.
-- Note: this is not guaranteed to be compatible with plenary.job.
-- Also note: you dont have to use this, this is designed for the system
-- processes in netman. Feel free to use whatever async/coroutine
-- logic you would like.

local compat = require("netman.tools.compat")
local uv = compat.uv

local Shell = {}
Shell.CONSTANTS = {
    FLAGS = {
        -- If provided, is used to join STDOUT into one string
        -- with the char(s) provided with this key as the
        -- join between each item in STDOUT
        STDOUT_JOIN = "STDOUT_JOIN",
        -- If provided, is used to join STDERR into one string
        -- with the char(s) provided with this key as the
        -- join between each item in STDERR
        STDERR_JOIN = "STDERR_JOIN",
        -- If provided, STDOUT will be dumped to this file.
        -- If the file doesn't exist, we will try to create it
        STDOUT_FILE = "STDOUT_FILE",
        -- If STDOUT_FILE is provided, this can be provided to specify
        -- that the STDOUT_FILE is binary. Default assumption is that the file
        -- is text
        STDOUT_FILE_IS_BINARY = "STDOUT_FILE_IS_BINARY",
        -- If STDOUT_FILE is provided, this can be provided to specify
        -- that the STDOUT_FILE should be truncated and overwritten.
        -- Default assumption is to append to the file
        STDOUT_FILE_OVERWRITE = "STDOUT_FILE_OVERWRITE",
        -- If provided, STDERR will be dumped to this file.
        -- If the file doesn't exist, we will try to create it
        STDERR_FILE = "STDERR_FILE",
        -- If STDERR_FILE is provided, this can be provided to specify
        -- that the STDERR_FILE is binary. Default assumption is that the file
        -- is text
        STDERR_FILE_IS_BINARY = "STDERR_FILE_IS_BINARY",
        -- If STDERR_FILE is provided, this can be provided to specify
        -- that the STDERR_FILE should be truncated and overwritten.
        -- Default assumption is to append to the file
        STDERR_FILE_OVERWRITE = "STDERR_FILE_OVERWRITE",
        -- If provided, the shell processes will run in
        -- Async mode. Use with exit_callback or
        -- STDOUT/STDERR CALLBACK. If you care about the
        -- output from the process. Run will return
        -- immediately when running in async mode
        ASYNC       = "ASYNC",
        -- If provided, a function is expected as the key,
        -- and the function will be called once the
        -- shell process completes. Will be provided
        -- the output of @see Shell:dump_self_to_table
        -- as the only param
        EXIT_CALLBACK = "EXIT_CALLBACK",
        -- If provided, a function is expected as the key,
        -- and the function will be called everytime
        -- STDOUT emits anything.
        STDOUT_CALLBACK = "STDOUT_CALLBACK",
        -- If provided, expects an integer and will
        -- limit the amount of content saved to the internal
        -- STDOUT buffer to this integer. Use if you expect
        -- alot of output you don't care about or set to 0
        -- if you are using STDOUT_CALLBACK
        STDOUT_PIPE_LIMIT = "STDOUT_PIPE_LIMIT",
        -- If provided, a function is expected as the key,
        -- and the function will be called everytime
        -- STDERR emits anything.
        STDERR_CALLBACK = "STDERR_CALLBACK",
        -- If provided, expects an integer and will
        -- limit the amount of content saved to the internal
        -- STDERR buffer to this integer. Use if you expect
        -- alot of output you don't care about or set to 0
        -- if you are using STDERR_CALLBACK
        STDERR_PIPE_LIMIT = "STDERR_PIPE_LIMIT",
        -- If provided, a function is expected as the value,
        -- and the function will be called the shell
        -- process receives any signals. Expects a return
        -- of true/false, where true indicates that the
        -- signal was consumed by the callback and false
        -- indicates that the signal wasn't consumed
        SIGNAL_CALLBACK  = "SIGNAL_CALLBACK",
        -- @see https://github.com/luvit/luv/blob/master/docs.md#uvspawnpath-options-on_exit
        ENV = "ENV",
        -- @see https://github.com/luvit/luv/blob/master/docs.md#uvspawnpath-options-on_exit
        UID = "UID",
        -- @see https://github.com/luvit/luv/blob/master/docs.md#uvspawnpath-options-on_exit
        GID = "GID",
        -- If provided, expects a boolean to indicate if you want the shell to run in detached mode
        -- or not. By default, this is set to false. Note, this will only work if @see ASYNC is also
        -- provided and _will_ throw an error if that option is not set too
        -- For more details, checkout @see https://github.com/luvit/luv/blob/master/docs.md#uvspawnpath-options-on_exit
        -- specifically the "detached" option that can be provided here
        DETACHED = "DETACHED"
    }
}

--- This will create the handler that is expected from @see Shell:run()
--- Note, this does _not_ create an asynchronous shell object. @see Shell:new for this. This is
--- explicitly to create the handler that is used to communicate with asynchronous netman.tools.shell
--- processes
--- @param type string
---     I understand this is alot to provide and create. Thus there a couple helper "shortcuts" that can
---     be used instead. This is done by specifying different `type`s. Below are the acceptable `type` values
---     that can be provided
---     - "manual" (See below for the requirements for that)
---     - "plenary"
---     - "vimjob"
--- 
--- @param handler_opts table
---     This is a bit complicated so hang on!
---     There are several ways to create a new async handler, and they are all associated with the
---     param `type` that is provided. Below is the table that is expected with the `"manual"` type.
---     - pid integer
---         - The current process pid
---     - read function
---         - @param read_target string | Optional
---             - Default: 'stdout'
---             - Valid Options ('stdout', 'stderr')
---             - This will read out the contents of either the stdout or stderr pipe
---         - @param save boolean | Optional
---             - Default: false
---             - If provided, will _not_ clear the pipe on read
---         - @return table
---             - A table containing each (single) line from the requested read target.
---     - write function
---         - @param data string
---             - Data to write to stdin
---             - WARN: This will throw an error if you try to write after the process is closed!
---     - close function
---         - @param force boolean | Optional
---             - Default: false
---             - This will close the shell process. Force will execute a kill -9 on the process.
---     - add_exit_callback function
---         - @param callback
---             - This should add a function to the available exit callbacks
---             - This function expects a table provided as its parameter and that table **needs to have
---             `exit_code` and `signal` attributes on it**
---    --------------------------------------------------------------------------------------------
---
---     Type `"plenary"` can take a standard Plenary Job and "wrap" it in a way that Netman can use for async
---     communication. See https://github.com/nvim-lua/plenary.nvim#plenaryjob for details
---     NOTE: This does _not_ cause plenary to be a requirement of this project. Netman will work fine without
---     plenary. However I do recognize that job management is painful (which is why Shell was created). Because
---     of this, this function will allow you to use plenary jobs, vim jobs, or netman jobs interchangably
---     throughout netman. Anything that expects a handler will be able to utilize what is returned
---     from this function regardless of how the job was started or what manages it (provided its one
---     of the above approved types)
---     - job table
---         - Whatever plenary returned from `Job:new` should be put here
---
---     Too good for plenary and netman? Feel free to use the inbuilt `job` system within vim! You will need
---     type `"vimjob"` for this
---     - id integer
---         - This is the job id that is provided via :h jobstart
---
--- @return table
---     - is_active boolean
---         - A bolean to indicate if the process handle is active.
---         - This will be true by default, so if it is false,
---         - you can assume that the process has ended for _some reason_
---     - pid integer
---         - The current process pid
---     - read function
---         - @param read_target string | Optional
---             - Default: 'stdout'
---             - Valid Options ('stdout', 'stderr')
---             - This will read out the contents of either the stdout or stderr pipe
---         - @param save boolean | Optional
---             - Default: false
---             - If provided, will _not_ clear the pipe on read
---         - @return table
---             - A table containing each (single) line from the requested read target.
---     - write function
---         - @param data string
---             - Data to write to stdin
---             - WARN: This will throw an error if you try to write after the process is closed!
---     - stop function
---         - @param force boolean | Optional
---             - Default: false
---             - This will stop the shell process. Force will execute a kill -9 on the process.
---     - add_exit_callback function
---         - @param callback function
---             - Saves the callback for later callback when the handle's underlying process is complete
---     - exit_code integer
---         - This will be nil until the process is stopped at which time it will be populated with
---         whatever the exit code was
---     - exit_signal string
---         - This will be nil until the process is stopped at which time it will be populated with
---         whatever the signal was on exit
function Shell.new_async_handler(type, handler_opts)
    -- We could probably break this into it separate functions but 🤷
    local handle = {
        is_active = true,
        pid = nil,
        read = nil,
        write = nil,
        stop = nil,
        exit_code = nil,
        exit_signal = nil,
        add_exit_callback = nil,
        __type = 'netman_shell_handle',
        __exit_callbacks = {},
        __dun = false
    }
    local required_attrs = {}
    if type == 'vimjob' then
        required_attrs = {"id"}
        for _, attr in ipairs(required_attrs) do
            assert(handler_opts[attr], string.format("No %s attribute provided with async handle!", attr))
        end
        -- Since jobs may be inside neovim, we are going to say the id is the pid
        handle.pid = handler_opts.id
        -- TODO: Finish setting this up. Looks like there might be some weirdness with
        -- reading from the stdio pipes here...
    elseif type == 'plenary' then
        required_attrs = {"job"}
        for _, attr in ipairs(required_attrs) do
            assert(handler_opts[attr], string.format("No %s attribute provided with async handle!", attr))
        end
        local success, _
        success, _ = pcall(function() handle.pid = handler_opts:pid() end)
        assert(success, "Unable to get pid from plenary job for Async Handle!")
        handle.read = function(target, save)
            -- We will _not_ manipulate the plenary pipe
            if target == 'stdout' and handler_opts.enable_recording then
                return handler_opts:result()
            end
            if target == 'stderr' and handler_opts.enable_recording then
                return handler_opts:stderr_result()
            end
        end
        handle.write = function(data)
            handler_opts:send(data)
        end
        handle.stop = function(force)
            handle.is_active = false
            -- It looks like plenary jobs don't have a force option. Omitting for now
            -- Also the function expects a code and signal.
            local signal = force and 9 or 15
            handler_opts:shutdown(-1, signal)
        end
        handler_opts:add_exit_callback(function(code, signal)
            handle.is_active = false
            handle.exit_code = code
            handle.exit_signal = signal
            handle.__dun = true
            for _, callback in ipairs(handle.__exit_callbacks) do
                callback(code, signal)
            end
        end)
        handle.add_exit_callback = function(callback)
            if handle.__dun then
                callback(handle.exit_code, handle.exit_signal)
                return
            end
            table.insert(handle.__exit_callbacks, callback)
        end
    else
        required_attrs = {"pid", "read", "write", "stop", "add_exit_callback"}
        for _, attr in ipairs(required_attrs) do
            assert(handler_opts[attr], string.format("No %s attribute provided with async handle!", attr))
            handle[attr] = handler_opts[attr]
        end
        assert(handler_opts.add_exit_callback, "No add exit_callback provided with async handle!")
        handler_opts.add_exit_callback(function(exit_info)
            handle.is_active = false
            handle.exit_code = exit_info.exit_code
            handle.exit_signal = exit_info.signal
            handle.__dun = true
            for _, callback in ipairs(handle.__exit_callbacks) do
                callback(exit_info.code, exit_info.signal)
            end
        end)
        handle.add_exit_callback = function(callback)
            handle.is_active = false
            if handle.__dun then
                callback(handle.exit_code, handle.exit_signal)
                return
            end
            table.insert(handle.__exit_callbacks, callback)
        end
    end
    return handle
end

--- Creates a new shell object (but does not start it)
--- @param command table
---     Array (table that is not key,value pairs) of commands to run
---     Note: due to how libuv
---     https://github.com/luvit/luv/blob/master/docs.md#uvspawnpath-options-on_exit
---     works, need this to be a single argument per item in the command.
---     Note: We do _not_ verify this, make sure you aren't writing 💩 code.
--- @param options table
---     @see Shell.CONSTANTS.FLAGS
--- @throws "Command must be a table!" error if the command is not a table
--- @throws "Cannot run empty command!" error if the command table is empty
function Shell:new(command, options)
    assert(type(command) == "table", "Command must be a table!")
    assert(#command > 0, "Cannot run empty command!")
    options = options or {}

    local new_shell = {}
    setmetatable(new_shell, self)
    self.__index = self
    Shell.reset(new_shell, command, options)
    return new_shell
end

function Shell:reset(command, options)
    command = command or self._orig_command or {}
    assert(type(command) == "table", "Command must be a table!")
    assert(#command > 0, "Cannot run empty command!")
    self.__type = 'netman_shell'
    self._orig_command = command
    self._command = command[1]
    options = options or self._options or {}
    self._options = options
    self._args = { compat.unpack(command, 2) }
    self._command_as_string = table.concat(command, " ")
    self._stdout_joiner = options[Shell.CONSTANTS.FLAGS.STDOUT_JOIN]
    self._stderr_joiner = options[Shell.CONSTANTS.FLAGS.STDERR_JOIN]
    self._stdout_file   = options[Shell.CONSTANTS.FLAGS.STDOUT_FILE]
    self._stderr_file   = options[Shell.CONSTANTS.FLAGS.STDERR_FILE]
    self._stdout_append = not options[Shell.CONSTANTS.FLAGS.STDOUT_FILE_OVERWRITE]
    self._stderr_append = not options[Shell.CONSTANTS.FLAGS.STDERR_FILE_OVERWRITE]
    self._stdout_is_binary = options[Shell.CONSTANTS.FLAGS.STDOUT_FILE_IS_BINARY]
    self._stderr_is_binary = options[Shell.CONSTANTS.FLAGS.STDERR_FILE_IS_BINARY]
    self._stdout_filehandle = nil
    self._stderr_filehandle = nil
    self._user_stdout_callbacks = {options[Shell.CONSTANTS.FLAGS.STDOUT_CALLBACK]} or {}
    self._user_stderr_callbacks = {options[Shell.CONSTANTS.FLAGS.STDERR_CALLBACK]} or {}
    self._user_signal_callback = options[Shell.CONSTANTS.FLAGS.SIGNAL_CALLBACK]
    self._stdout_pipe_limit = options[Shell.CONSTANTS.FLAGS.STDOUT_PIPE_LIMIT] or -1
    self._stderr_pipe_limit = options[Shell.CONSTANTS.FLAGS.STDERR_PIPE_LIMIT] or -1
    self._is_async = options[Shell.CONSTANTS.FLAGS.ASYNC]
    self._user_exit_callbacks = options[Shell.CONSTANTS.FLAGS.EXIT_CALLBACK] or {}
    self._env = options[Shell.CONSTANTS.FLAGS.ENV]
    self._uid = options[Shell.CONSTANTS.FLAGS.UID]
    self._gid = options[Shell.CONSTANTS.FLAGS.GID]
    self._detached = options[Shell.CONSTANTS.FLAGS.DETACHED]
    self._stdin_pipe = nil
    self._stdin_write_count = 0
    self._attempted_kill = false
    self._running = false
    self._stdout_pipe = nil
    self._stderr_pipe = nil
    self.stdout = {}
    self.stderr = {}
    self._process_handle = nil
    self.handle = nil
    self.signal = nil
    self.exit_code = nil
    self._pid = nil
    self._dun = false
    self._timeout_timer = nil
    self._start_time = nil
    self._end_time = nil

    if self._detached then
        assert(self._is_async, "Command cannot be detached and sychronous. Ensure you are specifying the ASYNC flag")
    end

    if type(self._user_exit_callbacks) == 'function' then
        self._user_exit_callbacks = {self._user_exit_callbacks}
    end
    if type(self._user_stdout_callbacks) == 'function' then
        self._user_stdout_callbacks = {self._user_stdout_callbacks}
    end
    if type(self._user_stderr_callback) == 'function' then
        self._user_stderr_callback = {self._user_stderr_callback}
    end
end

--- Internal command ran before run to ensure
--- everything is prepped properly
function Shell:_prepare()
    self._stdin_pipe = uv.new_pipe(false)
    self._stdout_pipe = uv.new_pipe(false)
    self._stderr_pipe = uv.new_pipe(false)
    self._stdin_write_count = 0
    self._cmd_opts = {
        args = self._args,
        stdio = {
            self._stdin_pipe, self._stdout_pipe, self._stderr_pipe
        },
        hide = true,
        env = self._env,
        uid = self._uid,
        gid = self._gid,
        detached = self._detached
    }
    if self._stdout_file then
        local flag = 'w+'
        if self._stdout_append then flag = 'a+' end
        local mode = ''
        if self._stdout_is_binary then mode = 'b' end
        local _ = string.format("%s%s", flag, mode)
        self._stdout_filehandle = io.open(self._stdout_file, _)
        assert(self._stdout_filehandle, string.format("Unable to open STDOUT File %s", self._stdout_file))
    end
    if self._stderr_file then
        local flag = 'w+'
        if self._stderr_append then flag = 'a+' end
        local mode = ''
        if self._stderr_is_binary then mode = 'b' end
        self._stderr_filehandle = io.open(self._stderr_file, string.format("%s%s", flag, mode))
        assert(self._stderr_filehandle, string.format("Unable to open STDERR File %s", self._stderr_file))
    end
    -- Generates a passable handle that can be used to read from, write to, and stop the process
    self.handle = {
        __type = 'netman_shell_handle',
        pid = nil,
        stop = function(force)
            Shell.stop(self, force)
        end,
        write = function(data)
            Shell.write(self, data)
        end,
        read = function(read_target, save)
            read_target = read_target or 'stdout'
            assert(read_target == 'stdout' or read_target == 'stderr', string.format("Invalid read target %s. Read target must be stdout or stderr", read_target))
            local pipe = {}
            local target_pipe = nil
            if read_target == 'stdout' then
                target_pipe = self.stdout
            else
                target_pipe = self.stderr
            end
            local pipe_length = #target_pipe
            for index=1, pipe_length do
                table.insert(pipe, target_pipe[index])
                if not save then target_pipe[index] = nil end
            end
            return pipe
        end,
        add_exit_callback = function(callback)
            Shell.add_exit_callback(self, callback)
        end
    }
end

function Shell:_stdout_callback(err, data)
    assert(not err, err)
    if not data then return end
    if #self._user_stdout_callbacks > 0 then
        for _, callback in ipairs(self._user_stdout_callbacks) do
            callback(data)
        end
    end
    if self._stdout_pipe_limit < 0 or #self.stdout < self._stdout_pipe_limit then
        ---@diagnostic disable-next-line: param-type-mismatch
        table.insert(self.stdout, data)
    end
    if self._stdout_filehandle then
        self._stdout_filehandle:write(data)
    end
end

function Shell:_stderr_callback(err, data)
    assert(not err, err)
    if not data then return end
    if #self._user_stderr_callbacks > 0 then
        for _ ,callback in ipairs(self._user_stderr_callbacks) do
            callback(data)
        end
    end
    if self._stderr_pipe_limit < 0 or #self.stderr < self._stderr_pipe_limit then
        ---@diagnostic disable-next-line: param-type-mismatch
        table.insert(self.stderr, data)
    end
    if self._stderr_filehandle then
        self._stderr_filehandle:write(data)
    end
end

--- Writes the provided data to the stdin pipe of the process
--- @param data string
---     The data to write to stdin
--- @throws "Please call Shell:run before trying to write to stdin!" if trying to write to stdin before calling Shell:run
function Shell:write(data)
    assert(self._running, "Please call Shell:run before trying to write to stdin!")
    if data then
        self._stdin_write_count = self._stdin_write_count + 1
        local callback = function(err)
            self._stdin_write_count = self._stdin_write_count - 1
            assert(not err, err)
        end
        self._stdin_pipe:write(data, callback)
    end
end

-- Closes the STDIN pipe. If you want to stop the shell process,
-- use @see Shell:stop instead
function Shell:close()
    self._stdin_pipe:shutdown()
    self._stdin_pipe:close()
end

--- Stops the current running process and cleanly closes everything out
--- This is safe to run even if the process isn't currently running
function Shell:stop(force)
    self._running = false
    local signal = 15
    if force or self._attempted_kill then signal = 9 end
    if self._stdin_write_count > 0 then
        local loop_count = 0
        local loop_limit = 11
        local last_write_count = self._stdin_write_count
        while self._stdin_write_count > 0 do
            uv.sleep(1)
            uv.run('once')
            -- If writes are still occuring, check again
            if self._stdin_write_count == last_write_count then
                loop_count = loop_count + 1
            else
                loop_count = 0
            end
            if loop_count >= loop_limit then
                -- We have waited 10 milliseconds for the writes to complete. Kill this?
                self:_stderr_callback(nil, "FROZEN WRITE LOCKS")
                self._stdin_write_count = 0
            end
        end
    end
    if self._is_async then
        uv.kill(self._pid, signal)
    end

    self._attempted_kill = true
end

--- Runs the command information provided in new. Can be chained (EG Shell:new():run())
--- @param timeout integer (milliseconds)
---     Default: 10 (seconds)
---     If provided, will restrict the run time to only the alloted timeout.
---     If <= 0, will attempt to wait until command is complete.
--- @return table/nil
---     @see Shell:dump_self_as_table()
---     Note: If the shell process is asynchronous, this
---     will return instead a table that contains a handle to the process, as well as 
---     the pid of the process. This will look like
---     { handle: table, pid: integer }
---     This handle will contain the following 4 attriutes.
---     - pid integer
---         - The current process pid
---     - read function
---         - @param read_target string | Optional
---             - Default: 'stdout'
---             - Valid Options ('stdout', 'stderr')
---             - This will read out the contents of either the stdout or stderr pipe
---         - @param save boolean | Optional
---             - Default: false
---             - If provided, will _not_ clear the pipe on read
---         - @return table
---             - A table containing each (single) line from the requested read target.
---     - write function
---         - @param data string
---             - Data to write to stdin
---             - WARN: This will throw an error if you try to write after the process is closed!
---     - close function
---         - @param force boolean | Optional
---             - Default: false
---             - This will close the shell process. Force will execute a kill -9 on the process.
---     NOTE: This handle will only be valid for the life of this current process. The handle will throw an error
---     if you try to use it after the life of the process (with the exception of read which will be valid until a new process is started)
---     If the process is not asynchronous, we will instead return the output of @see Shell:dump_self_as_table
function Shell:run(timeout)
    assert(not self._running, "Shell is already running!")
    timeout = timeout or (10 * 1000)
    self:_prepare()
    self._start_time = uv.hrtime()
    self._running = true
    self._process_handle, self._pid = uv.spawn(
        self._command,
        self._cmd_opts,
        function(exit_code, signal)
            self:_on_exit(exit_code, signal)
        end
    )
    if not self._process_handle then
        -- Something horrific happened. Exit immediately
        self:_stderr_callback(nil, "MISSING JOB HANDLE")
        self:close()
        self._running = false
        goto do_return
    end
    self.handle.pid = self._pid
    self._stdout_pipe:read_start(function(...) self:_stdout_callback(...) end)
    self._stderr_pipe:read_start(function(...) self:_stderr_callback(...) end)
    if timeout > 0 then
        self._timeout_timer = uv.new_timer()
        self._timeout_timer:start(timeout, 0, function()
            self:_stderr_callback(nil, "JOB TIMEOUT")
            self:close()
            self._running = false
        end)
    end
    if not self._is_async then
        while self._running do
            uv.run('once')
            uv.sleep(5)
        end
        -- Loop until done?
        return self:dump_self_to_table()
    ---@diagnostic disable-next-line: missing-return
    end
    ::do_return::
    return Shell.new_async_handler('manual', self.handle)
end

function Shell:add_exit_callback(callback)
    if self._dun then
        callback(self:dump_self_as_table())
        return
    end
    table.insert(self._user_exit_callbacks, callback)
end

function Shell:add_stdout_callback(callback)
    table.insert(self._user_stdout_callbacks, callback)
end

function Shell:add_stderr_callback(callback)
    table.insert(self._user_stderr_callbacks, callback)
end

function Shell:_on_exit(exit_code, signal)
    if self._user_signal_callback and self._user_signal_callback(signal) then
        -- This means the user decided that the signal they caught wasn't worth stopping?
        return
    end
    self._end_time = uv.hrtime()
    -- Ensures that data cannot be written to the closed pipe or anything else of that nature
    self.handle.write = function() error("Unable to write to closed handle!") end
    -- I mean, if you wanna close it after the fact, ok cool?
    self.handle.close = function() end
    if self._timeout_timer and not self._timeout_timer:is_closing() then
        ---@diagnostic disable-next-line: undefined-field
        self._timeout_timer:stop()
        ---@diagnostic disable-next-line: undefined-field
        self._timeout_timer:close()
    end
    -- NOTE: I wonder if we should be checking if we need to shutdown stdin?
    if not self._stdin_pipe:is_closing()  then
        self._stdin_pipe:shutdown()
        self._stdin_pipe:close()
    end
    if not self._process_handle:is_closing() then self._process_handle:close() end
    if not self._stdout_pipe:is_closing() then self._stdout_pipe:close() end
    if not self._stderr_pipe:is_closing() then self._stderr_pipe:close() end
    if self._stdout_filehandle then
        assert(self._stdout_filehandle:flush(), string.format("Unable to write STDOUT to %s", self._stdout_file))
        assert(self._stdout_filehandle:close(), string.format("Unable to close STDOUT file %s", self._stdout_file))
    end
    if self._stderr_filehandle then
        assert(self._stderr_filehandle:flush(), string.format("Unable to write STDERR to %s", self._stderr_file))
        assert(self._stderr_filehandle:close(), string.format("Unable to close STDERR file %s", self._stderr_file))
    end
    local stdout = {}
    local stderr = {}
    ---@diagnostic disable-next-line: param-type-mismatch
    local pre_stdout = table.concat(self.stdout)
    ---@diagnostic disable-next-line: param-type-mismatch
    local pre_stderr = table.concat(self.stderr)
    for line in pre_stdout:gmatch('[^\r\n]+') do
        table.insert(stdout, line)
    end
    for line in pre_stderr:gmatch('[^\r\n]+') do
        table.insert(stderr, line)
    end
    ---@diagnostic disable-next-line: cast-local-type
     if self._stdout_joiner then stdout = table.concat(stdout, self._stdout_joiner) end
    ---@diagnostic disable-next-line: cast-local-type
    if self._stderr_joiner then stderr = table.concat(stderr, self._stderr_joiner) end
    self.stdout = stdout
    self.stderr = stderr
    self.exit_code = exit_code
    self.signal = signal
    self._running = false
    self._dun = true
    local return_info = self:dump_self_to_table()
    if #self._user_exit_callbacks > 0 then
        for _, callback in ipairs(self._user_exit_callbacks) do
            callback(return_info)
        end
    else
        return return_info
    end
end

--- Dumps a table that contains the following keys
--- - command
---     The table command that was passed into our @see new function
--- - cmd_pieces
---     The command table that was provided
--- - signal
---     The signal received on on closure of process
--- - opts
---     The table options that were passed into our @see new function
--- - stdout
---     The standard output of the command if it has been ran. This may not be in the table if @see Shell:run hasn't been called yet
--- - stderr
---     The standard error of the command if it has been ran. This may not be in the table if @see Shell:run hasn't been called yet
--- - exit_code
---     The exit code from teh command if it has been ran. This may not be in the table if @see Shell:run hasn't been called yet
function Shell:dump_self_to_table()
    local cmd_pieces = {self._command}
    for _, arg in ipairs(self._args) do
        table.insert(cmd_pieces, arg)
    end
    local elapsed_time = self._end_time and self._end_time - self._start_time
    local elapsed_time_ml = self._end_time and (self._end_time - self._start_time) / 1000000
    return {
        pid = self._pid,
        command = self._command_as_string,
        cmd_pieces = cmd_pieces,
        opts = self._options,
        stdout = self.stdout,
        stderr = self.stderr,
        exit_code = self.exit_code,
        signal = self.signal,
        elapsed_time = self._end_time and self._end_time - self._start_time or 0,
        elapsed_time_ml = self._end_time and (self._end_time - self._start_time) / 1000000 or 0
    }
end

--- Waits for all the provided shells to finish.
--- NOTE: This _will_ lockup the thread running this command until all shells are finished
--- @param shells table
---     A 1 dimensional table of netman_shell_handle objects. See Shell.new_async_handler for details
--- @param sleep_check function | Optional
---     Default: nil
---     If provided, this will be called directly before each iteration of the "wait" loop is performed.
---     We will check the return of this function and if it is "truthy", we will stop the wait loop and cancel
---     all running shells. Basically, a quick dirty "stop all things"
function Shell.join(shells, sleep_check)
    if type(shells) ~= 'table' or #shells == 0 then
        -- I don't know what the hell you gave me but we are wrapping it in a table so it can "properly"
        -- fail later
        shells = { shells }
    end
    local waiting_shells = {}
    for _, shell in ipairs(shells) do
        assert(shell.__type == 'netman_shell_handle', string.format("Invalid object type %s. Must be a Netman Shell Handle", shell.__type))
        assert(shell.pid, "Unable to find pid for shell!")
        table.insert(waiting_shells, shell.pid)
        local callback = function()
            local index = -1
            for i, w_pid in ipairs(waiting_shells) do
                if w_pid == shell.pid then
                    index = i
                    break
                end
            end
            if index > -1 then
                -- This should always be the case but 🤷
                table.remove(waiting_shells, index)
            end
        end
        shell.add_exit_callback(callback)
    end
    local stop = false
    while #waiting_shells > 0 do
        uv.run('once')
        if sleep_check and sleep_check() then
            stop = sleep_check()
            if stop then
                break
            end
        end
        uv.sleep(1)
        -- Sleep for 1 millisecond and then run the uv loop once.
    end
    if stop then
        -- Caller requested full stop. Kill all the things
        for _, shell in ipairs(shells) do
            shell.stop(true)
        end
    end
end

return Shell
