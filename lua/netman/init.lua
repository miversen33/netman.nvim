vim.g.loaded_netrwPlugin = 1
vim.g.loaded_netrw = 1

vim.g.netman_no_shim = true

local utils  = require("netman.tools.utils")
local api    = require('netman.api')
local logger    = api.get_system_logger()

local M = {}

function M.read(...)
    -- This seems to be executing a lazy read, I am not sure I want that,
    -- and even if I do, I should figure out _why_ its doing a lazy
    -- read when that is not the design
    local files = { f = select("#", ...), ... }
    for _, file in ipairs(files) do
        if not file then goto continue end
        logger.infon("Fetching file: ", file)
        local data = api.read(file)
        local command = 'read ++edit '
        if not data then
            logger.warnf("No data was returned from netman api for %s", file)
            goto continue
        end
        if not data.success then
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
                else
                    logger.errorn(string.format("Netman Error: %s", data.error.message))
                    logger.infon("See netman logs for more details. :h Nmlogs")
                end
            end
            return
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
        require("netman.ui").render_command_and_clean_buffer(command)
        ::continue::
    end
end

function M.write(uri)
    uri = uri or vim.fn.expand('%')
    if uri == nil then
        logger.errorn("Write Incomplete! Unable to parse uri for buffer!")
        return
    end
    local buffer_index = vim.fn.bufnr(uri)
    local status = api.write(buffer_index, uri)
    if not status.success then
        logger.errorn(status.error.message)
        logger.error(status)
        return
    end
    vim.api.nvim_command('sil! set nomodified')
end

function M.delete(uri)
    if uri == nil then
        logger.warnn("No uri provided to delete!")
        return
    end
    api.delete(uri)
end

function M.init()
    if not M._setup_commands then
        logger.info("--------------------Netman Core Initializating!--------------------")
        logger.trace("Setting Commands")
        local commands = {
             'command! -nargs=1 NmloadProvider   lua require("netman.api").load_provider(<f-args>)'
            ,'command! -nargs=1 NmunloadProvider lua require("netman.api").unload_provider(<f-args>)'
            ,'command! -nargs=1 NmreloadProvider lua require("netman.api").reload_provider(<f-args>)'
            ,'command! -nargs=? Nmlogs           lua require("netman.api").generate_log(<f-args>)'
            ,'command! -nargs=1 Nmdelete         lua require("netman").delete(<f-args>)'
            ,'command! -nargs=+ Nmread           lua require("netman").read(<f-args>)'
            ,'command!          Nmwrite          lua require("netman").write()'
        }
        for _, command in ipairs(commands) do
            logger.trace("Setting Vim Command: " .. command)
            vim.api.nvim_command(command)
        end
        M._setup_commands = true
        logger.info("--------------------Netman Core Initialization Complete!--------------------")
    end
end

-- This exists solely so lazy can "properly" import this
function M.setup() end

-- Some helper objects attached to the M object that is returned on
-- require('netman') so you can chain things on setup
M.api = api
M.logger = api.get_consumer_logger()
M.utils = utils

M.init()
return M
