-- TODO: (Mike): Needs a compat layer for when new neovim features are added
-- So we can "target" versions with bootstrap and not need to download/build each point version
-- Should help protect against attacks that abuse any poorly written
-- vim emulation code below. Additionally should prevent this from
-- running while in a neovim environment
if vim then return end
local self_name = "bootstrap"

-- Attempts import of luv, if luv is not available it throws an error. Luv is what
-- neovim uses under the hood so ensure you have it installed and is accesible on your path
-- It can usually be installed via your package manager (apt-get install lua-luv, yum install lua-luv, etc)
-- but can also be installed via luarocks (luarocks install --local luv)
local status, luv = pcall(require, "luv")
if status == nil or status == false then
    error("Unable to run bootstrapper without luv. Please install luv!", 2)
end

local status, inspect = pcall(require, "inspect")
if status == nil or status == false then
    error("Unable to run boostrapper without inspect. Please install inspect!", 2)
end
local known_paths = {
    luv.os_homedir() .. "/.local/share/nvim/site/pack/packer/start/netman.nvim/lua/",
    luv.os_homedir() .. "/.local/share/nvim/site/pack/plugins/opt/netman.nvim/lua/"
}
local netman_path = nil
for _, path in ipairs(known_paths) do
    if luv.fs_stat(path) then
        netman_path = path
        break
    end
end
if not netman_path then
    error("Unable to locate netman!")
    return
end
package.path = netman_path .. "?.lua;" .. netman_path .. "?/init.lua;"  .. package.path
-- package.path =  "../?.lua;" .. package.path

local preloaded_packages = {}
preloaded_packages[self_name] = 1
-- Storing any packages that were loaded when we got here
-- we dont be reloading these
for key, _ in pairs(package.loaded) do
    preloaded_packages[key] = 1
end

local print = function(...)
    -- quick way to allow for "hushing" the output
    if not _G._QUIET then
        _G.print(...)
    end
end
local shell_escape_pattern = [[([%s^&*()%]="'+.|,<>?%[{}%\])]]
_G.vim = { g = {}, inspect=inspect, loop=luv }
_G.vim.fn = {}
_G.vim.api = {}
_G.inspect = inspect
_G.uv = luv
_G.vim.log = {
    levels = {
        TRACE = 0,
        DEBUG = 1,
        INFO = 2,
        WARN = 3,
        ERROR = 4,
    }
}

-- Creates "name" via the linux mkdir command
-- Will create subchildren if "path" == "p" (see :help mkdir in vim for details)
-- prot is unused currently, maybe we will implement how its used in neovim mkdir but
-- for now I dont care enough. Deal with it
function _G.vim.fn.mkdir(name, path, prot)
    local args = {}
    if path == "p" then table.insert(args, "-p") end
    -- name = name:gsub(shell_escape_pattern, "\\" .. "%1")
    table.insert(args, name)

    local stdout = luv.new_pipe(false)
    local stderr = luv.new_pipe(false)
    local _stdout = {}
    local _stderr = {}

    local handle = nil
    
    local command_options = {
        args = args,
        stdio = {nil, stdout, stderr},
        hide = true
    }
    handle, _ = luv.spawn("mkdir", command_options, function(exit_code, exit_signal)
        if #_stdout > 0 then print(table.concat(_stdout, "")) end
        handle:close()
        stdout:close()
        stderr:close()
        if exit_code ~= 0 then
            error("Received Error Code: " .. exit_code .. " and signal: " .. exit_signal .. " on mkdir request", 2)
        end
    end)
    luv.read_start(stdout, function(err, data)
        assert(not err, err)
        if data then table.insert(_stdout, data) end
    end)
    luv.read_start(stderr, function(err, data)
        assert(not err, err)
        if data then table.insert(_stderr, data) elseif #_stderr > 0 then error(table.concat(_stderr, ''), 2) end
    end)
    luv.run()
end

-- Janky version of the vim.fn.stdpath function (:help stdpath)
-- Only implements returns for cache, config and data
-- and doesn't look for if they are "correct" or not, assumes they are
-- in $HOME/.(cache|config|local)
-- Good enough for development purposes
function _G.vim.fn.stdpath(location)
    if location == "cache" then
        return luv.os_homedir() .. '/.cache/nvim'
    elseif location == "config" then
        return luv.os_homedir() .. '/.config/nvim'
    -- elseif location == "config_dirs" then
    elseif location == "data" then
        return luv.os_homedir() .. '/.local/share/nvim'
    -- elseif location == "data_dirs" then
    end
end

function _G.vim.deepcopy(orig)
-- https://stackoverflow.com/a/640645/2104990
-- Hippity hoppity this code is now my property. Unless it fails,
-- then its the fault of someone who's not me
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[vim.deepcopy(orig_key)] = vim.deepcopy(orig_value)
        end
        setmetatable(copy, vim.deepcopy(getmetatable(orig)))
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

-- Cheats and uses libuv's readlink (I would bet thats what neovim
-- is doing anyway
function _G.vim.fn.resolve(path)
    return luv.fs_readlink(path)
end

function _G.vim.fn.getpid()
    return luv.os_getppid()
end

function _G.vim.fn.delete(path, opts)
    -- TODO: Mike: we should probably implement this sometime but there is no easy way
    -- to recursively delete the contents of a directory and I'm lazy
end

-- Prints to screen your message instead of notifying the user via
-- vim's notification modal. Ya know, since we aren't in vim anymore
function _G.vim.api.nvim_notify(message, level, opts)
    print("Notify --- [" .. level .. "]: " .. message)
end

-- Prints the vim command received instead of running it
function _G.vim.api.nvim_command(command)
    print("Would run `:" .. tostring(command) .. "`")
end

-- Returns an empty array. This is _basically_ a stub function
function _G.vim.api.buf_get_lines(buffer_index, start_line, end_line, strict_indexing)
    return {}
end

function _G.vim.api.nvim_create_autocmd(event, opts)
    print("Would create aucommand for " .. event, inspect(opts))
end

function _G.vim.api.nvim_del_augroup_by_name(augroup)
    print("Would delete augroup " .. augroup)
end

function _G.vim.api.nvim_clear_autocmds(opts)
    print("Would delete autocommands for options", inspect(opts))
end

function _G.vim.api.nvim_create_augroup(augroup)
    print("Would create augroup " .. augroup)
end
-- I'm 99% certain this doesn't need to exist.
-- @deprecated
function _G.vim.fn.expand(path)
    return path
end

function _G.reload_packages(packages)
    if not packages then
        packages = {}
        for package, _ in pairs(package.loaded) do
            table.insert(packages, package)
        end
    end
    local ignore_preloaded = true
    if packages == 'all' then ignore_preloaded = false end
    if type(packages) == 'string'
        then packages = { packages }
    end
    local r = {}
    for _, p in ipairs(packages) do
        if preloaded_packages[p] and ignore_preloaded then
            goto continue
        end

        print("    - unloading " .. p)
        if p:match(self_name .. "$") then
            print("Reloading " .. self_name .. " But be aware nothing will change with it as it has a memory check to prevent duplicate loads...")
        end
        package.loaded[p] = nil
        table.insert(r, p)
        ::continue::
    end
    for _, reload_package in ipairs(r) do
        print("    + reloading " .. reload_package)
        require(reload_package)
    end
end

function _G.clear()
    os.execute("clear")
end
