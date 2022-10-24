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

local M = {}


M.icon = function(config, node, state)
    local _icon = common.icon(config, node, state)
    local internal_node = netman.internal.get_internal_node(node:get_id())
    if internal_node then
        if internal_node.type == 'netman_provider' then
            _icon.text = "  "
        end
        if internal_node.icon then
            _icon.text = string.format("%s ", internal_node.icon)
        end
        _icon.highlight = internal_node.hl or _icon.highlight
    end
    return _icon
end

M.state = function(config, node, state)
    local internal_node = netman.internal.get_internal_node(node:get_id())

    local _state = "  "
    if internal_node and internal_node.state then
        _state = string.format("%s ", internal_node.state)
    end
    return {
        text = _state,
        highlight = nil
    }
end

return vim.tbl_deep_extend("force", common, M)
