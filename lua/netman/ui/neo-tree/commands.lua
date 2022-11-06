--This file should contain all commands meant to be used by mappings.
local cc = require("neo-tree.sources.common.commands")

local M = {}

--- This will reach out to an internal function for handling subtree navigation (ish?)
M.open = function(state, callback)
    -- Probably should figure out how to get this to handle splits and such first?
    ---@diagnostic disable-next-line: missing-parameter
    require("netman.ui.neo-tree").navigate(state)
    if callback and type(callback) == 'function' then callback() end
end

-- TODO:
M.add_directory = function(state, callback)

end

--- This will reach out to netman's api to create the new item in question
M.add = function(state, callback)
    
end

-- TODO:
M.refresh = function(state, callback)
    require("netman.ui.neo-tree").refresh(state)
    if callback and type(callback) == 'function' then callback() end
end

-- TODO:
M.rename = function(state, callback)

end

-- TODO:
M.delete = function(state, callback)

end
M.delete_visual = function(state, selected_nodes, callback)
    for _, node in pairs(selected_nodes) do
        M.delete(state, node)
    end
    if callback and type(callback) == 'function' then callback() end
end

cc._add_common_commands(M)
return M
