local _sane_defaults = {
    log_level = 4
}

local utils = require('netman.utils')

-- utils.adjust_log_level(1)

local api = require('netman.api')
local log = utils.log
local notify = utils.notify

local M = {}

function M:read(...)
    local files = { f = select("#", ...), ... }
    for _, file in ipairs(files) do
        notify.warn("Fetching file: " .. file)
        local command = api:read(nil, file)
        if not command then
            log.warn("No command returned for read of " .. file)
            goto continue
        end
        local undo_levels = vim.api.nvim_get_option('undolevels')
        vim.api.nvim_command('keepjumps sil! 0')
        vim.api.nvim_command('keepjumps sil! setlocal ul=-1 | ' .. command)
        vim.api.nvim_command('keepjumps sil! 0d')
        vim.api.nvim_command('keepjumps sil! setlocal ul=' .. undo_levels .. '| 0')
        ::continue::
    end
end

function M:write(uri)
    if uri == nil then
        uri = uri or vim.fn.expand('%')
    end
    if uri == nil then
        notify.error("Write Incomplete! Unable to parse uri for buffer!")
        return
    end
    local buffer_index = vim.fn.bufnr(uri)
    notify.debug("Saving File: " .. uri .. " on buffer: " .. buffer_index)
    api:write(buffer_index, uri)
end

function M:delete(uri)
    if uri == nil then
        notify.warn("No uri provided to delete!")
        return
    end
    api:delete(uri)
end

function M:config(options)
    options = options or {}
    if options.debug then
        -- utils.adjust_log_level(1)
        log.debug("Setting Netman in debug mode!")
    end
    log.debug("Setup Called!")
end

function M:init()
    log.debug("Init called! Should it run? " .. tostring(M._setup_commands))
    if not M._setup_commands and not vim.g.loaded_netman then
        log.debug("Setting Commands")
        local commands = {
             'command -nargs=1 NmloadProvider lua require("netman.api"):load_provider(<f-args>)'
            ,'command -nargs=? Nmlogs         lua require("netman.api").dump_info(<f-args>)'
            ,'command -nargs=1 Nmdelete       lua require("netman"):delete(<f-args>)'
            ,'command -nargs=+ Nmread         lua require("netman"):read("file", <f-args>)'
            ,'command          Nmwrite        lua require("netman"):write("buf", vim.fn.bufnr())'
            ,'command -nargs=1 Nmbrowse       lua require("netman"):read(nil, <f-args>)'
        }
        for _, command in ipairs(commands) do
            log.debug("Setting Vim Command: " .. command)
            vim.api.nvim_command(command)
        end
    end
    M._setup_commands = true
    vim.g.loaded_netman = 1
    vim.g.loaded_netrwPlugin = 1
    vim.g.loaded_netrw = 1 -- TODO(Mike) By disabling netrw, we prevent ANY netrw handling of files. This is probably bad, we may want to consider a way to allow some of NetRW to function.
end

    -- EG, this disables NetRW's local directory handling which is not amazing.
    -- Alternatively, we build our own internal file handling...?

M:init()
return M
