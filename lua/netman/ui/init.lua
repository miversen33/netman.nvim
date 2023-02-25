local logger = require("netman.api").get_system_logger()
local M = {
    internal = {},
    get_logger = require("netman.api").get_consumer_logger
}

--- Returns a configuration specifically for whatever UI consumer is requesting it.
--- If the consumer doesn't have a configuration, we will create it for them on request
--- @param consumer string
---     The path to the consumer. For example, netman.ui.neo-tree
--- @return Configuration
function M.get_config(consumer)
    local ui_config = require("netman.api").internal.get_config('netman.ui')
    local consumer_config = ui_config:get(consumer)
    if not consumer_config then
        logger.info(string.format("Creating new UI configuration for %s", consumer))
        consumer_config = require("netman.tools.configuration"):new()
        consumer_config.save = ui_config.save
        ui_config:set(consumer, consumer_config)
        ui_config:save()
    elseif not consumer_config.__type or consumer_config.__type ~= 'netman_config' then
        -- We got _something_ but its not a netman configuration. Most likely this
        -- was a config but was serialized out and newly loaded in from a json
        consumer_config = require("netman.tools.configuration"):new(consumer_config)
        consumer_config.save = ui_config.save
    end
    return consumer_config
end

function M.render_command_and_clean_buffer(render_command, opts)
    opts = {
        nomod = 1,
        detect_filetype = 1
    } or opts
    local undo_levels = vim.api.nvim_get_option('undolevels')
    vim.api.nvim_command('keepjumps sil! 0')
    vim.api.nvim_command('keepjumps sil! setlocal ul=-1 | ' .. render_command)
    -- if opts.filetype then
    --     vim.api.nvim_command(string.format('set filetype=%s', opts.filetype))
    -- end
    -- TODO: (Mike): This actually adds the empty line to the default register. consider a way to get
    -- 0"_dd to work instead?
    vim.api.nvim_command('keepjumps sil! 0d')
    vim.api.nvim_command('keepjumps sil! setlocal ul=' .. undo_levels .. '| 0')
    if opts.nomod then
        vim.api.nvim_command('sil! set nomodified')
    end
    if opts.detect_filetype then
        vim.api.nvim_command('sil! filetype detect')
    end
end

return M
