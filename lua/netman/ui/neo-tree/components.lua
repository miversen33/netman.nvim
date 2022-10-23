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

local M = {}

M.name = function(config, node, state)
    local highlight = config.highlight or highlights.FILE_NAME
    return {
        text = "IS TEST",
        highlight = highlight,
    }
end

--
-- require("netman.tools.utils").log.debug("HELLO!")

return vim.tbl_deep_extend("force", common, M)
