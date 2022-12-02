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

M.add = function(state, callback)
    ui.add_node(state)
    do_callback(callback)
end

M.refresh = function(state, callback)
    ui.refresh(state)
    do_callback(callback)
end

M.rename = function(state, callback)
    ui.rename_node(state)
    do_callback(callback)
end

-- TODO:
M.delete = function(state, callback)
    ui.delete_node(state)
    do_callback(callback)
end

M.move = function(state, callback)
    ui.move_node(state)
    do_callback(callback)
end

-- -- TODO:
--
-- TODO:
M.cut_to_clipboard = function(state, callback)
    local node = state.tree:get_node()
    return M.cut_to_clipboard_visual(state, {node}, callback)
end
--
-- TODO:
-- Takes the selected nodes and "marks" them as cut.
M.cut_to_clipboard_visual = function(state, selected_nodes, callback)
    require("netman.tools.utils").log.debug({nodes=selected_nodes})
    for _, node in ipairs(selected_nodes) do
        ui.mark_node(node, ui.constants.MARK.cut)
    end
    do_callback(callback)
end
--
-- -- TODO:
M.paste_from_clipboard = function(state, callback)
    ui.process_marked_nodes(state, {
        ui.constants.MARK.cut,
        ui.constants.MARK.copy
    })
    do_callback(callback)
end
M.delete_visual = function(state, selected_nodes, callback)
    for _, node in pairs(selected_nodes) do
        M.delete(state, node)
    end
    do_callback(callback)
end

cc._add_common_commands(M)
return M
