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
        local data = api.read(file)
        local command = 'read ++edit '
        if not data then
            log.warn(string.format("No data was returned from netman api for %s", file))
            goto continue
        end
        if data.error then
            if data.error.callback then
                local default = data.error.default or ""
                local callback = function(input)
                    local response = data.error.callback(input)
                    if response and response.retry then
                        M.read(file)
                    end
                end
                vim.ui.input({
                    prompt = data.error.message,
                    default = default,
                    },
                    callback
                )
                return
            end
        end
        if data.type == 'EXPLORE' then
            -- Figure out what we want netman itself to do when directory is open?
            goto continue
        elseif data.type == 'STREAM' then
            command = '0append! ' .. table.concat(data.data)
        else
            command = string.format("%s %s", command, data.data.local_path)
        end
        if vim.fn.bufexists(file) ~= 0 then
            -- Create a buffer
            local buffer = vim.fn.bufnr(file)
            vim.api.nvim_set_current_buf(buffer)
            vim.api.nvim_buf_set_name(0, file)
        end
        require("netman.tools.utils").render_command_and_clean_buffer(command)
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
