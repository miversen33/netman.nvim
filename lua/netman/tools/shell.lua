-- Heavily inspired by
-- https://github.com/nvim-lua/plenary.nvim/blob/master/lua/plenary/job.lua
-- This is a stripped down version of plenary's "job" api.
-- Note: this is not guaranteed to be compatible with plenary.job.
-- Also note: you dont have to use this, this is designed for the system
-- processes in netman. Feel free to use whatever async/coroutine
-- logic you would like.

local compat = require("netman.tools.compat")

local Shell = {}

--- Creates a new shell object (but does not start it)
--- @param command table
---     Array (table that is not key,value pairs) of commands to run
---     Note: due to how libuv
---     https://github.com/luvit/luv/blob/master/docs.md#uvspawnpath-options-on_exit
---     works, need this to be a single argument per item in the command.
---     Note: We do _not_ verify this, make sure you aren't writing 💩 code.
--- @param options table
---     Options is a table (or nil) with any of the following key value pairs (optional)
---     exit_callback: function
---         A function to call when Shell:run has completed
---     async: boolean
---         If true, Shell:run will return immediately and process in the background
---         If false, will attempt to intelligently block until done processing.
---         Note: Shell:run can take a timeout param to deal with runaway trains 🚂🚂
---     netman.tools.options.STDOUT_JOIN: string
---         If provided, each entry in stdout will be joined with this string
---         Note: this converts stdout to a string as opposed to an array
---     netman.tools.options.STDERR_JOIN: string
---         If provided, each entry in stderr will be joined with this string
---         Note: this converts stderr to a string as opposed to an array
--- @param std_callbacks table
---     Table with the following (optional) key,value pairs
---     stdout: callback
---     stderr: callback
---     Note, stdout and stderr callbacks are not provided, the output from
---     these streams will be returned in a table
--- @throws "Command must be a table!" error if the command is not a table
--- @throws "Cannot run empty command!" error if the command table is empty
function Shell:new(command, options, std_callbacks)
    assert(type(command) == "table", "Command must be a table!")
    assert(#command > 0, "Cannot run empty command!")

    local new_shell = {}
    std_callbacks = std_callbacks or {}
    options = options or {}
    setmetatable(new_shell, self)

    new_shell._command = command[1]
    new_shell._args = { compat.unpack(command, 2) }
    new_shell._command_as_string = table.concat(command, " ")
    new_shell._stdout_joiner   = options[require("netman.tools.options").utils.command.STDOUT_JOIN]
    new_shell._stderr_joiner   = options[require("netman.tools.options").utils.command.STDERR_JOIN]
    new_shell._stdout_callback = std_callbacks.stdout
    new_shell._stderr_callback = std_callbacks.stderr
    new_shell._is_async = options.async
    new_shell._exit_callback = options.exit_callback
    new_shell._env = options.env
    new_shell._uid = options.uid
    new_shell._gid = options.gid

    self.__index = self
    return new_shell
end

--- Writes the provided data to the stdin pipe of the process
--- @param data string
---     The data to write to stdin
--- @throws "Please call Shell:run before trying to write to stdin!" if trying to write to stdin before calling Shell:run
function Shell:write(data)
    assert(self._starting, "Please call Shell:run before trying to write to stdin!")
    self._stdin_pipe:write(data)
end

--- Runs the command information provided in new. Can be chained (EG Shell:new():run())
--- @param timeout integer (milliseconds)
---     Default: 10 (seconds)
---     If provided, will restrict the run time to only the alloted timeout.
---     If <= 0, will attempt to wait until command is complete.
--- @return table/nil
---     Returns the following table or nil
---     {
---         stdout=stdout, -- may be nil if std_callbacks contains a callback for stdout
---         stderr=stderr, -- may be nil if std_callbacks contains a callback for stderr
---         exit_code=exit_code
---     }
---     If options contains an exit_callback, we will return nothing
function Shell:run(timeout)
    timeout = timeout or (10 * 1000)
    assert(not self._starting, "Shell is already running!")
    self._starting = true
    self._handle = nil
    self._pid    = nil
    self.stderr = nil
    self.stdout = nil
    self.exit_code = nil
    self._job_timeout = timeout
    self._job_timer = nil
    self._stdout_pipe = vim.loop.new_pipe(false)
    self._stderr_pipe = vim.loop.new_pipe(false)
    self._stdin_pipe  = vim.loop.new_pipe(false)
    self._cmd_options = {
        args = self._args
        ,stdio = {
            self._stdin_pipe
            ,self._stdout_pipe
            ,self._stderr_pipe
        }
        ,hide = true
        ,env = self._env
        ,uid = self._uid
        ,gid = self._gid
    }
    self._stdout = {}
    self._stderr = {}
    if not self._stdout_callback then
        self._tmp_stdout_callback = true
        self._stdout_callback = function(data)
            table.insert(self._stdout, data)
        end
    end
    if not self._stderr_callback then
        self._tmp_stdout_callback = true
        self._stderr_callback = function(data)
            table.insert(self._stderr, data)
        end
    end
    local return_info = nil
    if self._is_async then
        self:_run_async()
    else
        return_info = self:_run_sync()
    end
    vim.loop.run('nowait')
    return return_info
end

function Shell:_run_async()
    assert(self._starting, "Please call Shell:run()!")
    local exit_callback = function(exit_code, _)
        if self._job_timer then
            self._job_timer:stop()
            self._job_timer:close()
        end
        if not self._handle:is_closing() then
            self._handle:close()
        end
        self:_on_exit(exit_code, _)
    end
    self:_run(exit_callback)
end

function Shell:_run_sync()
    assert(self._starting, "Please call Shell:run()!")
    assert(self._job_timeout > 0, "Cannot have infinite timeout on synchronous job!")
    local feedback_timer = nil
    feedback_timer = vim.loop.new_timer()
    local exit_callback = function(exit_code, _)
        feedback_timer:stop()
        feedback_timer:close()
        if self._job_timer then
            self._job_timer:stop()
            self._job_timer:close()
        end
        self._handle:close()
        self:_on_exit(exit_code, _)
    end
    self:_run(exit_callback)
    while self._handle:is_active() do
        feedback_timer:start(5, 5,
            function()
                if not self._handle:is_active() then
                    feedback_timer:stop()
                    feedback_timer:close()
               end
            end)
        vim.loop.run('once')
    end
    return {stdout=self.stdout, stderr=self.stderr, exit_code=self.exit_code}
end

--- Runs the command after setup by new() and run()
--- Note: Do not call this
function Shell:_run(exit_callback)
    assert(self._starting, "Please call Shell:run()!")
    local handle, pid =
        vim.loop.spawn(
            self._command
            ,self._cmd_options
            ,exit_callback
        )
    assert(handle, "Failed to start command: " .. tostring(self._command_as_string))
    self._handle = handle
    self._pid = pid
    self._stdout_pipe:read_start(function(err, data)
        assert(not err, err)
        self._stdout_callback(data)
    end)
    self._stderr_pipe:read_start(function(err, data)
        assert(not err, err)
        self._stderr_callback(data)
    end)
    if self._job_timeout > 0 then
        self._job_timer = vim.loop.new_timer()
        self._job_timer:start(self._job_timeout, 0, function()
            self._job_timer:stop()
            self._job_timer:close()
            self._handle:close(exit_callback)
            self._job_timer = nil
            require("netman.tools.utils").log.warn(self._command_as_string .. " timed out!")
        end)
    end
end

function Shell:_on_exit(exit_code, _)
    local stdout = {}
    local stderr = {}

    local pre_stdout = table.concat(self._stdout)
    for line in pre_stdout:gmatch("[^\r\n]+") do
        table.insert(stdout, line)
    end
    local pre_stderr = table.concat(self._stderr)
    for line in pre_stderr:gmatch("[^\r\n]+") do
        table.insert(stderr, line)
    end

    if self._stdout_joiner then stdout = table.concat(stdout, self._stdout_joiner) end
    if self._stderr_joiner then stderr = table.concat(stderr, self._stderr_joiner) end
    local return_info = {stdout=stdout, stderr=stderr, return_code = exit_code}
    self.exit_code = exit_code
    self.stdout = stdout
    self.stderr = stderr
    self._stdout_pipe:close()
    self._stderr_pipe:close()
    self._stdin_pipe:close()
    if self._tmp_stdout_callback then self._stdout_callback = nil end
    if self._tmp_stderr_callback then self._stderr_callback = nil end
    self._tmp_stdout_callback = nil
    self._tmp_stderr_callback = nil
    self._job_timer = nil
    self._starting = false
    if self._exit_callback then
        self._exit_callback(return_info)
    else
        return return_info
    end
end

return Shell
