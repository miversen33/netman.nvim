local netman_options = require("netman.options")
local utils = require('netman.utils')
local log = utils.log
local notify = utils.notify

local M = {}

M._cache = {}
M.version = 0.1
M.protocol_patterns = netman_options.protocol.EXPLORE
M.debug = true

function M:explore(explore_details)
    local cache_key = utils.generate_string(10)
    local parent = explore_details.parent
    local output = {'../'}
    M._cache[cache_key] = {parent}
    for i, detail in ipairs(explore_details.remote_files) do
        if detail.uri == parent.uri then
            goto continue
        end
        detail.parent = parent
        table.insert(M._cache[cache_key], detail)
        local line = detail.fullname
        if detail.type == 'd' and detail.fullname:sub(-1) ~= '/' then
            line = line .. '/'
        end
        table.insert(output, line)
        ::continue::
    end
    local buffer = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, output)
    vim.api.nvim_buf_set_option(buffer, 'filetype', 'NetmanExplore')
    vim.api.nvim_buf_set_option(buffer, 'modifiable', false)
    vim.api.nvim_buf_set_keymap(buffer, 'n', '<Enter>', ":lua require('netman.providers.explorer'):line_interact('" .. cache_key .. "', vim.fn.line('.'))<CR>", {noremap=true, silent=true})

end

function M:line_interact(cache_key, line_number)
    local cache = M._cache[cache_key]
    log.debug("Loaded cache object: ", cache[line_number])
    vim.api.nvim_buf_delete(vim.api.nvim_get_current_buf(), {force=true})
    require("netman"):read(cache[line_number].uri) -- TODO(Mike): There is something about how this is firing off that doesn't set the proper unmodified flag?
end

return M