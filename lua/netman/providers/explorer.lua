local netman_options = require("netman.options")
local utils = require('netman.utils')
local log = utils.log

local M = {}

M._cache = {}
M.version = 0.1
M.protocol_patterns = netman_options.protocol.EXPLORE
M.debug = true

local _clear_cache = function(cache)
    local count = #cache; for i=0, count do cache[i] = nil end
end

function M:explore(parent, explore_details)
    _clear_cache(M._cache)
    local buffer = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_option(buffer, 'filetype', 'NetmanExplore')
    vim.api.nvim_buf_set_option(buffer, 'modifiable', true)
    local output = {}
    for _, detail in ipairs(explore_details) do
        table.insert(output, detail.title)
        table.insert(M._cache, detail)
    end
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, output)
    vim.api.nvim_buf_set_option(buffer, 'modified', false)
    vim.api.nvim_buf_set_option(buffer, 'modifiable', false)
    vim.api.nvim_command('0')
    vim.api.nvim_buf_set_keymap(buffer, 'n', '<Enter>', ":lua require('netman.providers.explorer'):open(vim.fn.line('.'))<CR>", {noremap=true, silent=true})
end

function M:open(index)
    local shim = require("netman.providers.explore_shim")
    log.debug("Opening item: ", {item=M._cache[index]})
    shim:interact_via_callback(M._cache[index][netman_options.explorer.FIELDS.URI])
end

return M