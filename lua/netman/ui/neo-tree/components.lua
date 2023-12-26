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
local icon_map = function(item) return '' end
local success, web_devicons = pcall(require, "nvim-web-devicons")
if success then
    icon_map = web_devicons.get_icon
end

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
    [netman_host_states.REFRESHING] = {text=M.internal.refresh_icon, highlight=""}
}

M.action = function(config, node, state)
    local _icon = { text = '', highlight = '' }
    local entry = node.extra
    if not entry then return end
    _icon.text = node.extra.action or ''
    return _icon
end

M.marked = function(config, node, state)
    local _icon = { text = '', highlight = '' }
    local entry = node.extra
    if not entry or not (entry.markable and entry.marked) then
        return
    end
    _icon.text = M.internal.marked_icon
    return _icon
end

M.expanded = function(config, node, state)
    local _icon = nil
    if node:is_expanded() then
        _icon = { text = '', highlight = '' }
    end
    return _icon
end

M.icon = function(config, node, state)
    local _icon = common.icon(config, node, state)
    local entry = node.extra
    if not entry then
        return _icon
    end
    if entry.refresh then
        _icon.text = M.internal.refresh_icon
    elseif entry.error then
        _icon.text = M.internal.state_map.ERROR.text
    elseif entry.icon then
        _icon.text = string.format("%s ", entry.icon)
    elseif node.type == 'netman_host' then
        _icon.text, _icon.highlight = icon_map(entry.os)
        -- Use this as a place to have the OS icon?
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
    icon = string.format("%s", icon)
    return {
        text = icon,
        highlight = highlight
    }
end

return vim.tbl_deep_extend("force", common, M)
