--This file should contain all commands meant to be used by mappings.
local cc = require("neo-tree.sources.common.commands")
local ui = require("netman.ui.neo-tree")
local M = {}

local do_callback = function(callback)

    if callback and type(callback) == 'function' then callback() end
end
--- This will reach out to an internal function for handling subtree navigation (ish?)
M.open = function(state, callback)
    -- Probably should figure out how to get this to handle splits and such first?
    ui.navigate(state)
    do_callback(callback)
end

-- TODO:
M.add_directory = function(state, callback)
    ui.add_node(state, {force_dir=true})
    do_callback(callback)
end

--- This will reach out to netman's api to create the new item in question
M.add = function(state, callback)
    ui.add_node(state)
    do_callback(callback)
end

-- TODO:
M.refresh = function(state, callback)
    ui.refresh(state)
    do_callback(callback)
end

-- TODO:
M.rename = function(state, callback)
    do_callback(callback)
end

-- TODO:
M.delete = function(state, callback)
    ui.delete(state)
    do_callback(callback)
end

-- -- TODO:
M.delete_visual = function(state, selected_nodes, callback)
    for _, node in pairs(selected_nodes) do
        M.delete(state, node)
    end
    do_callback(callback)
end

cc._add_common_commands(M)
return M
