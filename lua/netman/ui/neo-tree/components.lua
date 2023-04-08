-- This file contains the built-in components. Each componment is a function
-- that takes the following arguments:
--      config: A table containing the configuration provided by the user
--              when declaring this component in their renderer config.
--      node:   A NuiNode object for the currently focused node.
--      state:  The current state of the source providing the items.
--
-- The function should return either a table, or a list of tables, each of which
-- contains the following keys:
--    text:      The text to display for this item.
--    highlight: The highlight group to apply to this text.

local highlights = require("neo-tree.ui.highlights")
local common = require("neo-tree.sources.common.components")
local netman = require("netman.ui.neo-tree")
local netman_host_states = require("netman.tools.options").ui.STATES
local log = require("netman.tools.utils").log

local M = {
    internal = {
        refresh_icon = " ",
        marked_icon = '♦ ',
    }
}

M.internal.state_map = {
    [netman_host_states.UNKNOWN] = {text=" ", highlight=""},
    [netman_host_states.AVAILABLE] = {text=" ", highlight="NeoTreeGitAdded"},
    [netman_host_states.ERROR] = {text="❗", highlight="NeoTreeGitDeleted"},
}

M.marked = function(config, node, state)
    local _icon = { text = '', highlight = '' }
    local entry = node.extra
    if not entry or not (entry.markable and entry.marked) then
        return
    end
    _icon.text = M.internal.marked_icon
    return _icon
end

M.icon = function(config, node, state)
    local _icon = common.icon(config, node, state)
    local entry = node.extra
    if not entry then
        return _icon
    end
    if node.refresh then
        _icon.text = ''
    elseif node.type == 'netman_host' then
        -- Use this as a place to have the OS icon?
        _icon.text = ''
    elseif node.type == 'netman_refresh' then
        _icon.text = M.internal.refresh_icon
    end
    if entry.icon then
        _icon.text = string.format("%s ", entry.icon)
    end
    _icon.highlight = entry.highlight or _icon.highlight
    return _icon
end

M.state = function(config, node, state)
    local icon = "  "
    local highlight = nil
    local entry = node.extra
    if not entry then
        return {
            text = icon,
            highlight = highlight
        }
    end
    local _state = M.internal.state_map[entry.state]
    if _state then
        icon = _state.text
        highlight = _state.highlight
    end
    if entry.refresh then
        icon = ' '
        highlight = ''
    end
    icon = string.format("%s", icon)
    return {
        text = icon,
        highlight = highlight
    }
end

return vim.tbl_deep_extend("force", common, M)
