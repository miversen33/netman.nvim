--This file should contain all commands meant to be used by mappings.
local cc = require("neo-tree.sources.common.commands")

local M = {}

--- This will reach out to an internal function for handling subtree navigation (ish?)
M.open = function(state)
    require("netman.ui.neo-tree").navigate(state, nil)
end

cc._add_common_commands(M)
return M
