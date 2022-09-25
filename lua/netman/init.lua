vim.g.netman_log_level = 0
vim.g.loaded_netrwPlugin = 1
vim.g.loaded_netrw = 1

-- vim.g.netman_no_shim = true

local api    = require('netman.api')
local utils  = require("netman.tools.utils")
local log    = utils.log
local notify = utils.notify
local libruv = require('netman.tools.libruv')
local netman_enums = require("netman.tools.options")

local M = {}

function M.read(...)
    -- This seems to be executing a lazy read, I am not sure I want that,
    -- and even if I do, I should figure out _why_ its doing a lazy
    -- read when that is not the design
    local files = { f = select("#", ...), ... }
    for _, file in ipairs(files) do
        if not file then goto continue end
        notify.info("Fetching file: ", file)
        local command = api.read(file)
        log.trace(string.format("Received read command: %s", command))
        if not command then
            log.warn(string.format("No command returned for read of %s", file))
            goto continue
        end
        local mapped_file, is_shortcut = api.check_if_path_is_shortcut(file, 'remote_to_local')
        if is_shortcut and vim.fn.bufexists(mapped_file) then
            local buffer = vim.fn.bufnr(mapped_file)
            vim.api.nvim_set_current_buf(buffer)
            vim.api.nvim_buf_set_name(0, file)
            vim.api.nvim_command('file ' .. file)
        end
        if vim.fn.bufexists(file) == 0 then
            vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
            vim.api.nvim_command('file ' .. file)
        end
        local undo_levels = vim.api.nvim_get_option('undolevels')
        vim.api.nvim_command('keepjumps sil! 0')
        vim.api.nvim_command('keepjumps sil! setlocal ul=-1 | ' .. command)
        -- TODO: (Mike): This actually adds the empty line to the default register. consider a way to get
        -- 0"_dd to work instead?
        vim.api.nvim_command('keepjumps sil! 0d')
        vim.api.nvim_command('keepjumps sil! setlocal ul=' .. undo_levels .. '| 0')
        vim.api.nvim_command('sil! set nomodified')
        ::continue::
    end
end

function M.write(uri)
    uri = uri or vim.fn.expand('%')
    if uri == nil then
        notify.error("Write Incomplete! Unable to parse uri for buffer!")
        return
    end
    local buffer_index = vim.fn.bufnr(uri)
    notify.info("Saving File: " .. uri .. " on buffer: " .. buffer_index)
    api.write(buffer_index, uri)
    vim.api.nvim_command('sil! set nomodified')
end

function M.delete(uri)
    if uri == nil then
        notify.warn("No uri provided to delete!")
        return
    end
    api.delete(uri)
end

function M.init()
    if not M._setup_commands then
        local start_time = vim.loop.hrtime()
        log.trace("Setting Commands")
        local commands = {
            'command -nargs=1 NmloadProvider lua require("netman.api").load_provider(<f-args>)'
            ,'command -nargs=1 NmunloadProvider lua require("netman.api").unload_provider(<f-args>)'
            ,'command -nargs=1 NmreloadProvider lua require("netman.api").reload_provider(<f-args>)'
            ,'command -nargs=? Nmlogs         lua require("netman.api").dump_info(<f-args>)'
            ,'command -nargs=1 Nmdelete       lua require("netman").delete(<f-args>)'
            ,'command -nargs=+ Nmread         lua require("netman").read(<f-args>)'
            ,'command          Nmwrite        lua require("netman").write()'
            ,'command -nargs=1 Nmbrowse       lua require("netman").read(nil, <f-args>)'
        }
        for _, command in ipairs(commands) do
            log.trace("Setting Vim Command: " .. command)
            vim.api.nvim_command(command)
        end
        log.trace("Overriding File Explorers for Remote Resource Interactions")
        for _, _package in ipairs(netman_enums.explorer.EXPLORER_PACKAGES) do
            api.register_explorer_package(_package)
        end
        M._setup_commands = true
        local end_time = vim.loop.hrtime() - start_time
        log.info("Netman Initialization Complete: Took approximately " .. (end_time / 1000000) .. "ms")
    end
end

-- Some helper objects attached to the M object that is returned on
-- require('netman') so you can chain things on setup
M.api = api
M.log = utils.log
M.notify = utils.notify
M.libruv = libruv
M.utils = utils

M.do_test = function()

    local stdout = vim.loop.new_pipe()
    local stderr = vim.loop.new_pipe()
    local stdin = vim.loop.new_pipe()
    vim.loop.read_start(stdout, function(data)
        -- Not sure why but stdout is not getting called here for this command?
        print(string.format("STDOUT: %s", data))
    end)
    vim.loop.read_start(stderr, function(data)
        print(string.format("STDERR: %s", data))
    end)
    vim.loop.spawn("ssh", {
        args = {"piserver"},
        stdio = {stdin, stdout, stderr}
    })
end

M.init()
return M
