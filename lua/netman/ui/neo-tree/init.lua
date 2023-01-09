--This file should have all functions that are in the public api and either set
--or read the state of this source.

-- TODO: Ensure that we cant interact with search node unless its actively displayed....

local renderer = require("neo-tree.ui.renderer")
local events = require("neo-tree.events")
local neo_tree_utils = require("neo-tree.utils")
local defaults = require("netman.ui.neo-tree.defaults")
local input = require("neo-tree.ui.inputs")
local log = require("netman.tools.utils").log
local notify = require("netman.tools.utils").notify
local api = require("netman.api")
local CACHE_FACTORY = require("netman.tools.cache")

-- TODO: Let this be configurable via neo-tree
local CACHE_TIMEOUT = CACHE_FACTORY.FOREVER

local M = {
    name = "remote",
    default_config = defaults,
    -- Enum vars
    constants = {
        MARK = {
            delete = "delete",
            copy   = "copy",
            cut    = "cut",
            open   = "open"
        },
        ROOT_IDS = {
            NETMAN_RECENTS   = "netman_recents",
            NETMAN_FAVORITES = "netman_favorites",
            NETMAN_PROVIDERS = "netman_providers",
            NETMAN_SEARCH    = "netman_search"
        },
        TYPES = {
            NETMAN_PROVIDER = "netman_provider",
            NETMAN_BOOKMARK = "netman_bookmark",
            NETMAN_HOST     = "netman_host"
        },
        DEFAULT_EXPIRATION_LIMIT = CACHE_FACTORY.MINUTE -- 1 Minute. We will adjust this accordingly
    },
    internal = {
        -- Table of configurations specific to each provider...?
        provider_configs = {},
        sorter = {},
        marked_nodes = {},
        -- Used for temporarily removing nodes from view
        node_cache = {},
        -- Internal representation of the tree to display
        tree = {}
    }
}
-- Breaking this out into its own assignment because it has references to M
-- Extra item doc
-- - icon
--     - The icon to be displayed by Neotree
-- - highlight
--     - The color to use for vim highlighting
-- - static
--     - Indicates that this child will not change within neotree. Useful for knowing if the node 
--     being viewed (later) is dynamically created or not
-- - expandable
--     - Indicates that this item can be expanded by the user
M.constants.ROOT_CHILDREN =
{
    {
        id = M.constants.ROOT_IDS.NETMAN_SEARCH,
        name = "",
        type = M.constants.TYPES.NETMAN_BOOKMARK,
        children = {},
        skip_node = true,
        extra = {
            -- TODO: Idk, pick a better icon?
            icon = "",
            static = true
        }
    },
    {
        id = M.constants.ROOT_IDS.NETMAN_RECENTS,
        name = 'Recents',
        type = M.constants.TYPES.NETMAN_BOOKMARK,
        children = {},
        extra = {
            expandable = true,
            icon = "",
            highlight = "",
            static = true
        }
    },
    {
        id = M.constants.ROOT_IDS.NETMAN_FAVORITES,
        name = "Favorites",
        type = M.constants.TYPES.NETMAN_BOOKMARK,
        children = {},
        extra = {
            expandable = true,
            icon = "",
            highlight = "",
            static = true,
        }
    },
    {
        id = M.constants.ROOT_IDS.NETMAN_PROVIDERS,
        name = "Providers",
        type = M.constants.TYPES.NETMAN_BOOKMARK,
        children = {},
        extra = {
            expandable = true,
            -- TODO: Idk, pick a better icon?
            icon = "",
            highlight = "",
            static = true,
        }
    }
}
-- TODO: Figure out a way to make a constant variable????

-- Sorts nodes in ascending order
M.internal.sorter.ascending = function(a, b) return a.name < b.name end

-- Sorts nodes in descending order
M.internal.sorter.descending = function(a, b) return a.name > b.name end

-- M.internal.generate_root_children = function()
--     -- Root Tree
--     return {
--         {
--             id = 'netman_recents',
--             name = 'Recents',
--             type = "netman_bookmark",
--             children = {},
--             extra = {
--                 icon = "",
--                 highlight = "",
--                 provider = "",
--             }
--         },
--         {
--             id = "netman_favorites",
--             name = "Favorites",
--             type = "netman_bookmark",
--             children = {},
--             extra = {
--                 icon = "",
--                 highlight = "",
--                 provider = "",
--             }
--         },
--         {
--             id = "netman_providers",
--             name = "Providers",
--             type = "netman_bookmark",
--             children = {},
--             extra = {
--                 -- TODO: Idk, pick a better icon?
--                 icon = "",
--                 highlight = "",
--                 provider = "",
--             }
--         }
--     }
-- end

-- M.internal.get_providers = function()
--     local providers = {}
--     for _, provider_path in ipairs(api.providers.get_providers()) do
--         local status, provider = pcall(require, provider_path)
--         if not status or not provider.ui then
--             -- Failed to import the provider for some reason
--             -- or the provider is not UI ready
--             if not provider.ui then
--                 log.info(string.format("%s is not ui ready, it is missing the ui attribute", provider_path))
--             end
--             goto continue
--         end
--         table.insert(providers, {
--             -- Provider's (in this context) are unique as they are 
--             -- import paths from netman.api
--             id = provider_path,
--             name = provider.name,
--             type = "netman_provider",
--             children = {},
--             extra = {
--                 icon = provider.ui.icon or "",
--                 highlight = provider.ui.highlight or "",
--                 provider = provider_path,
--             }
--         })
--         ::continue::
--     end
--     table.sort(providers, M.internal.sorter.ascending)
--     return providers
-- end

-- M.internal.get_provider_children = function(provider)
--     local hosts = {}
--     for _, host in ipairs(api.providers.get_hosts(provider)) do
--         local host_details = api.providers.get_host_details(provider, host)
--         if not host_details then
--             log.warn(string.format("%s did not return any details for %s", provider, host))
--             goto continue
--         end
--         table.insert(hosts, {
--             id = host_details.URI,
--             name = host_details.NAME,
--             type = "netman_host",
--             children = {},
--             extra = {
--                 state = host_details.STATE,
--                 last_access = host_details.LAST_ACCESSED,
--                 provider = provider,
--                 host = host,
--                 uri = host_details.URI,
--                 searchable = true
--             }
--         })
--         ::continue::
--     end
--     table.sort(hosts, M.internal.sorter.ascending)
--     return hosts
-- end

-- M.internal.get_uri_children = function(state, uri, opts)
--     opts = opts or {}
--     local children = {}
--     -- Get the output from netman.api.read
--     -- Do stuff with that output?
--     local output = api.read(uri)
--     if not output then
--         log.info(string.format("%s did not return anything on read", uri))
--         return nil
--     end
--     if output.error then
--         local _error = output.error
--         local message = _error.message
--         -- Handle the error?
--         -- The error wants us to do a thing
--         if _error.callback then
--             local default = _error.default or ""
--             local parent_id = state.tree:get_node():get_parent_id()
--             local callback = function(_)
--                 local response = _error.callback(_)
--                 if response.retry then
--                     -- Do a retry of ourselves???
--                     M.refresh(state, {refresh_only_id=parent_id, auto=true})
--                 end
--             end
--             input.input(message, default, callback)
--             return nil
--         else
--             if not opts.ignore_unhandled_errors then
--                 -- No callback was provided, display the error and move on with our lives
--                 print(string.format("Unable to read %s, received error %s", uri, message))
--                 log.warn(string.format("Received error while trying to run read of uri: %s", uri), {error=message})
--             end
--             return nil
--         end
--     end
--     if output.type == 'FILE' or output.type == 'STREAM' then
--         -- Make neo-tree create a buffer for us
--         local command = ""
--         local open_command = 'read ++edit'
--         local event_handler_id = "netman_dummy_file_event"
--         if output.type == 'STREAM' then
--             command = '0append! ' .. table.concat(output.data) .. command
--         else
--             command = string.format("%s %s %s", open_command, output.data.local_path, command)
--         end
--         local dummy_file_open_handler = {
--             event = "file_opened",
--             id = event_handler_id
--         }
--         dummy_file_open_handler.handler = function()
--             events.unsubscribe(dummy_file_open_handler)
--         end
--         events.subscribe(dummy_file_open_handler)
--         neo_tree_utils.open_file(state, uri)
--         return children
--     end
--     local unsorted_children = {}
--     local children_map = {}
--     for _, item in ipairs(output.data) do
--         local child = {
--             id = item.URI,
--             name = item.NAME,
--             extra = {
--                 uri = item.URI,
--                 markable = true,
--                 searchable = false
--             }
--         }
--         if item.FIELD_TYPE == 'LINK' then
--             child.type = 'directory'
--             child.children = {}
--             child.extra.searchable = true
--         else
--             child.type = 'file'
--         end
--         table.insert(unsorted_children, child.name)
--         children_map[child.name] = child
--     end
--     local sorted_children = neo_tree_utils.sort_by_tree_display(unsorted_children)
--     for _, child in ipairs(sorted_children) do
--         table.insert(children, children_map[child])
--     end
--     return children
-- end

-- M.internal.generate_node_children = function(state, node, opts)
--     opts = opts or {}
--     local children = {}
--     if not node then
--         -- No node was provided, assume we want the root providers
--         children = M.internal.generate_root_children()
--     elseif node.id == 'netman_providers' then
--         children = M.internal.get_providers()
--     elseif node.type == "netman_provider" then
--         if not node.extra.provider then
--             -- SCREAM!
--             log.error(string.format("Node %s says its a provider but doesn't have a provider. How tf????", node.name), {node=node})
--             return children
--         end
--         children = M.internal.get_provider_children(node.extra.provider, opts)
--     else
--         if not node.extra.uri then
--             -- SCREAM!
--             log.error(string.format("Node %s says its a netman node, but has no URI. How tf????", node.name), {node=node})
--             return children
--         end
--         children = M.internal.get_uri_children(state, node.extra.uri, opts)
--     end
--     return children
-- end

-- M.add_node = function(state, opts)
--     local tree, node
--     opts = opts or {}
--     tree = state.tree
--     node = tree:get_node()
--     if node.type == 'netman_provider' then
--         print("Adding new hosts to a provider isn't supported. Yet... 👀")
--         return
--     end
--     local message = "Enter name of new file/directory. End the name in / to make it a directory"
--     if opts.force_dir then
--         message = "Enter name of new directory"
--     end
--     local callback = function(response)
--         if opts.force_dir and response:sub(-1, -1) ~= '/' then
--             response = string.format("%s/", response)
--         end
--         -- Check to see if node is a directory. If not, get its parent
--         if node.type ~= 'directory' then tree:get_node(node:get_parent_id()) end
--         M.internal.add_item_to_node(state, node, response)
--     end
--     -- Check if the node is active before trying to add to it
--     -- Prompt for new item name
--     -- Create new item in netman.api with the provider ui and parent path
--     -- Refresh the parent only
--     -- Navigate to the item
--     input.input(message, "", callback)
-- end

-- M.internal.rename = function(old_uri, new_uri)
--     return api.move(old_uri, new_uri)
-- end

--- Renames the selected or target node
--- @param state NeotreeState
--- @param target_node_id string
---     The node to target for deletion. If not provided, will use the
---     currently selected node in state
M.rename_node = function(state, target_node_id)
    local tree, node, current_uri, parent_uri, parent_id
    tree = state.tree
    node = tree:get_node(target_node_id)
    if not node.extra then
        log.warn(string.format("%s says its a netman node but its lyin", node.name))
        return
    end
    if node.type == 'netman_provider' then
        notify.info(string.format("Providers cannot be renamed at this time"))
        return
    end
    if node.type == 'netman_host' then
        notify.info(string.format("Hosts cannot be renamed at this time"))
        return
    end
    current_uri = node.extra.uri
    parent_id = node:get_parent_id()
    parent_uri = tree:get_node(parent_id).extra.uri

    local message = string.format("Rename %s", node.name)
    local default = ""
    local callback = function(response)
        if not response then return end
        local new_uri = string.format("%s%s", parent_uri, response)
        local success = api.rename(current_uri, new_uri)
        if not success then
            notify.warn(string.format("Unable to move %s to %s. Please check netman logs for more details", current_uri, new_uri))
            return
        end
        M.refresh(state, {refresh_only_id=parent_id, quiet=true})
        -- Rename any buffers that currently have the old uri as their name
        for _, buffer_number in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_get_name(buffer_number) == current_uri then
                vim.api.nvim_buf_set_name(buffer_number, new_uri)
            end
        end
        renderer.focus_node(state, new_uri)
    end
    input.input(message, default, callback)
end

--- Marks a node for future operation. Currently supported "future" operations are
--- - copy
--- - cut
--- - delete
--- - refresh
--- @param state NeotreeState (table)
---     The state provided to the caller by Neotree
M.mark_node = function(state)
    assert(state, "No state provided")
    assert(state.tree, "No tree associated with state")
    local node = state.tree:get_node()
    assert(node, "No node associated with tree")

    if not node.extra or node.extra.markable == nil then
        -- Node is not markable
        log.debug(string.format("Cannot mark node %s, its not listed as markable", node.name))
        return
    end
    if node.extra.marked then
        M.internal.marked_nodes[node.id] = nil
        node.extra.marked = false
    else
        M.internal.marked_nodes[node.id] = true
        node.extra.marked = true
    end
    renderer.redraw(state)
end

M.internal.confirm_target_node = function(node_name, success_callback, action_message)
    action_message = action_message or 'target'
    node_name = node_name or ''
    local message = string.format("Are you sure you want to %s %s [Y/n]", action_message, node_name)
    local confirm_callback = function(response)
        if response:match('^[yY]') then
            success_callback()
        end
    end
    input.input(message, "Y", confirm_callback)
end

--- Performs the requested action on the marked nodes.
--- @param state NeotreeState (table)
---     The state that is provided to the caller of this function
--- @param action string
---     The action to perform. Valid actions are
---     - copy
---     - delete
---     - move
---     - refresh
M.perform_mark_action = function(state, action)
    -- TODO: Probably better to make a table and just call out of that instead?
    if action == 'copy' then
        M.copy_nodes(state)
    elseif action == 'move' then
        M.move_nodes(state)
    elseif action == 'delete' then
        M.delete_nodes(state)
    elseif action == 'refresh' then
        M.refresh_nodes(state)
    end
    -- As long as the mark action succeded, we should clear our marks
    for id, _ in pairs(M.internal.marked_nodes) do
        local node = state.tree:get_node(id)
        if node then
            node.extra.marked = false
        end
    end
    M.internal.marked_nodes = {}
    renderer.redraw(state)
end

M.refresh_nodes = function(state)
    assert(state, "No state provided")
    assert(state.tree, "No tree associated with state")
    if not next(M.internal.marked_nodes) then
        -- There were no marked nodes, thats ok, we can just use the current node and perform a refresh on 
        -- the single node
        M.internal.marked_nodes = { [state.tree:get_node().id] = true }
    end
    -- TODO: Mike, it might be worth redoing refresh slightly to handle multi refresh
    -- instead of calling it several times on its own
    for uri, _ in pairs(M.internal.marked_nodes) do
        M.refresh(state, { refresh_only_id = uri })
    end
end

M.copy_nodes = function(state)
    if not next(M.internal.marked_nodes) then
        notify.warn("No nodes selected for copy! Please mark nodes to copy before pasting them")
        return
    end
    assert(state, "No state provided")
    assert(state.tree, "No tree associated with state")
    local target_node = state.tree:get_node()
    assert(target_node, "No node associated with tree")
    -- If target_node is not expandable, we should not use it, get its parent instead
    if
        target_node.type == M.constants.TYPES.NETMAN_BOOKMARK or target_node.type == M.constants.TYPES.NETMAN_PROVIDER
        or not target_node.extra
    then
        notify.warn(string.format("%s is not a valid copy target. Please select a different location", target_node.name))
        return
    end
    while not target_node.extra.expandable do
        -- The selected node cannot be "expanded" (IE, its not a parent type in the tree).
        -- Get its parent and use that for the target
        if target_node.extra.static then
            -- We reached the top of the tree and still didn't find anything to paste into.
            -- Not really sure the best way to handle this, complain for now
            notify.error("Unable to find valid copy node target!")
            return
        end
        target_node = state.tree:get_node(target_node:get_parent_id())
    end
    local uris = {}
    for uri, _ in pairs(M.internal.marked_nodes) do
        table.insert(uris, uri)
    end
    local callback = function()
        local copy_status = api.copy(uris, target_node.id)
        if not copy_status.success then
            log.error("Received error while trying to copy nodes", {nodes = uris, target = target_node.id, error = copy_status.error.message})
            notify.error("Unable to copy nodes. Check netman logs for details. :h Nmlogs")
            return
        end
        if not target_node:is_expanded() then
            M.navigate(state, {target_id = target_node.id})
        else
            M.refresh(state, {refresh_only_id = target_node.id, quiet = true})
        end
        notify.info(string.format("Successfully Copied %s nodes into %s", #uris, target_node.name))
    end
    M.internal.confirm_target_node(target_node.name, callback, 'copy to')
end

M.move_nodes = function(state)
    if not next(M.internal.marked_nodes) then
        notify.warn("No nodes selected for move! Please mark nodes to move before pasting them")
        return
    end
    assert(state, "No state provided")
    assert(state.tree, "No tree associated with state")
    local target_node = state.tree:get_node()
    assert(target_node, "No node associated with tree")
    -- If target_node is not expandable, we should not use it, get its parent instead
    if
        target_node.type == M.constants.TYPES.NETMAN_BOOKMARK or target_node.type == M.constants.TYPES.NETMAN_PROVIDER
        or not target_node.extra
    then
        notify.warn(string.format("%s is not a valid move target. Please select a different location", target_node.name))
        return
    end
    while not target_node.extra.expandable do
        -- The selected node cannot be "expanded" (IE, its not a parent type in the tree).
        -- Get its parent and use that for the target
        if target_node.extra.static then
            -- We reached the top of the tree and still didn't find anything to paste into.
            -- Not really sure the best way to handle this, complain for now
            notify.error("Unable to find valid move node target!")
            return
        end
        target_node = state.tree:get_node(target_node:get_parent_id())
    end
    local uris = {}
    local uri_parents = {}
    for uri, _ in pairs(M.internal.marked_nodes) do
        uri_parents[state.tree:get_node(uri):get_parent_id()] = true
        table.insert(uris, uri)
    end
    local callback = function()
        log.info("Moving Nodes")
        local move_status = api.copy(uris, target_node.id, { cleanup = true })
        if not move_status.success then
            log.error("Received error while trying to copy nodes", {nodes = uris, target = target_node.id, error = move_status.error.message})
            notify.error("Unable to copy nodes. Check netman logs for details. :h Nmlogs")
            return
        end
        for parent_id, _ in pairs(uri_parents) do
            M.refresh(state, {refresh_only_id = parent_id, auto = true, quiet = true})
        end
        if not target_node:is_expanded() then
            M.navigate(state, {target_id = target_node.id})
        else
            M.refresh(state, {refresh_only_id = target_node.id, quiet = true})
        end
        notify.info(string.format("Successfully Moved %s nodes into %s", #uris, target_node.name))
    end
    M.internal.confirm_target_node(target_node.name, callback, 'move to')
end

M.delete_nodes = function(state)
    log.info("Deleting Nodes")
    assert(state, "No state provided")
    assert(state.tree, "No tree associated with state")
    local uris = {}
    local uri_parents = {}
    for uri, _ in pairs(M.internal.marked_nodes) do
        uri_parents[state.tree:get_node(uri):get_parent_id()] = true
        table.insert(uris, uri)
    end
    if not next(uris) then
        -- There were no marked nodes, thats ok, we can just use the current node and perform a single delete
        uris = {state.tree:get_node().id}
        uri_parents = {[state.tree:get_node():get_parent_id()] = true}
    end
    local callback = function()
        for _, uri in ipairs(uris) do
            local delete_status = api.delete(uri)
            -- TODO: A status is not returned from api.delete, but it probably will be eventually and we should care
            -- about the answer
        end
        for parent_id, _ in pairs(uri_parents) do
            M.refresh(state, { refresh_only_id = parent_id, auto = true, quiet = true})
        end
        notify.info(string.format("Successfully deleted %s nodes", #uris))
    end
    local message = string.format("delete %s nodes", #uris)
    M.internal.confirm_target_node('', callback, message)
end

-- M.copy_nodes = function(state, nodes, target_node)
--     
-- end

-- M.open_nodes = function(state, nodes)
--
-- end

-- M.internal.hide_root_nodes = function(state)
--     for _, node in ipairs(state.tree:get_nodes()) do
--         node.extra.previous_state = node:is_expanded()
--         node:collapse()
--     end
-- end

-- M.internal.show_root_nodes = function(state)
--     for _, node in ipairs(state.tree:get_nodes()) do
--         if node.extra.previous_state then node:expand() end
--     end
-- end

-- M.search = function(state)
--     local node = state.tree:get_node()
--     if node.type == 'netman_provider' then
--         notify.warn("Cannot perform search on a provider!")
--         return
--     end
--     -- I don't know that this is right. The idea is that
--     -- if the node is a directory, we should be able to search it,
--     -- however we should also allow for grepping the file....?
--     if not node.extra.searchable then
--         node = state.tree:get_node(node:get_parent_id())
--     end
--     local message = "Search Param"
--     local default = ""
--     local uri = node.extra.uri
--     -- Must be positive integer, there should be no file depth that is 100000 deep. Yaaaa jank
--     local depth = 100000
--     local callback = function(response)
--         -- Hide nodes?
--         M.internal.hide_root_nodes(state)
--         state.tree:get_node('netman_search').skip_node = false
--         renderer.redraw(state)
--         -- NEED TO STAT THE OUTPUT SO WE KNOW HOW TO DISPLAY IT
--         local stdout = {}
--         local stdout_callback = function(item)
--             if not item or not item.ABSOLUTE_PATH then return end
--             log.debug(item)
--             -- This hardcode makes it so we expect data to come back in unix compliant paths...
--             local parent = stdout
--             for item_node in item.ABSOLUTE_PATH:gmatch('[^/]+') do
--                 local child_node = {
--                     id = "find://" .. item_node.URI,
--                     name = item_node.NAME,
--                     type = 'file',
--                     extra = {
--                         uri = item.URI,
--                     }
--                 }
--                 if item_node ~= item.NAME then
--                     child_node.type = 'directory'
--                 end
--                 local new_parent = nil
--                 for _, child in ipairs(parent) do
--                     if child.name == item_node then
--                         new_parent = child
--                     end
--                 end
--                 if not new_parent then new_parent = parent end
--                 if not new_parent.children then new_parent.children = {} end
--                 table.insert(new_parent.children, child_node)
--                 -- This may cause some issues but it _shouldn't_
--                 parent = new_parent
--             end
--             -- local first_line = nil
--             -- local last_line = nil
--             -- for line in output:gmatch('[^\r\n]+') do
--                 -- log.debug("Line: " .. line)
--                 -- if not first_line then first_line = line end
--                 -- last_line = line
--                 -- log.debug(string.format("Processing %s", line))
--             -- local parent = stdout
--             -- for part in output:gmatch('[^/]+') do
--             --     if part:sub(-1, -1) ~= '/' then
--             --         table.insert(parent, part)
--             --     else
--             --         parent[part] = {}
--             --     end
--             --     parent = parent[part]
--             -- end
--             -- log.debug({first_line = first_line, last_line = last_line})
--         end
--         local exit_callback = function()
--             log.debug("Complete Search Tree", stdout)
--         end
--         log.debug(
--             api.search(
--                 uri,
--                 response,
--                 {
--                     max_depth       = depth,
--                     search          = 'filename',
--                     case_sensitive  = false,
--                     async           = true,
--                     stdout_callback = stdout_callback,
--                     exit_callback   = exit_callback
--                 }
--             )
--         )
--     end
--     input.input(message, default, callback)
-- end

M.internal.delete_item = function(uri)
    local status, _error = pcall(api.delete, uri)
    if not status then
        log.warn(string.format("Received error while trying to delete uri %s", uri), {error=_error})
        return false
    end
    return true
end


--- query_type can either be "host" or "provider"
M.internal.query_node_tree = function(tree, node, query_type)
    query_type = query_type or'netman_provider'
    if query_type == 'host' then
        query_type = 'netman_host'
    end
    assert(tree, "No tree provided for query")
    assert(node, "No node provided for query")
    local _ = node
    while node.type ~= query_type do
        local parent_id = node:get_parent_id()
        if not parent_id then
            -- Something horrific happened and we somehow escaped
            -- the node path!
            log.warn("I don't know how you did it chief, but you provided a node outside a recognized node path", {provided_node = _})
            return nil
        end
        node = tree:get_node(parent_id)
    end
    return node
end

M.internal.show_node = function(state, node)
    local host = M.internal.query_node_tree(state.tree, node, 'host')
    if not host then
        log.warn("Unable to locate host for node!", node)
        return
    end
    host.extra.hidden_children[node.id] = nil
    node.skip_node = node.extra and node.extra.skip_node
    renderer.redraw(state)
    return true
end

M.internal.hide_node = function(state, node)
    local host = M.internal.query_node_tree(state.tree, node, 'host')
    if not host then
        log.warn("Unable to locate host for node!", node)
        return
    end
    if not host.extra then host.extra = {} end
    if not host.extra.hidden_children then host.extra.hidden_children = {} end
    node.extra.skip_node = node.skip_node or false
    node.skip_node = true
    host.extra.hidden_children[node.id] = node
    renderer.redraw(state)
    return true
end

M.internal.unfocus_path = function(state, node)
    assert(state, "No stated provided!")
    assert(node, "No node provided")
    local host = M.internal.query_node_tree(state.tree, node, 'host')
    if not host then
        log.warn("Unable to locate host for node!", node)
        return
    end
    -- Host has no children hidden
    if not host.extra or not host.extra.hidden_children then
        return true
    end
    for _, child in pairs(host.extra.hidden_children) do
        child.skip_node = child.extra and child.extra.skip_node
    end
    renderer.redraw(state)
    renderer.focus_node(state, node.id)
end

M.internal.focus_path = function(state, start_node, end_node)
    assert(state, "No state provided!")
    assert(start_node, "No starting node provided!")
    local tree = state.tree
    assert(tree, "No neotree associated with provided state!")
    -- If no end node is provided, we will simply use the host as the end
    local inspect_node = start_node
    local previous_node = nil
    local hidden_children = {}
    local keep_running = true
    while keep_running do
        -- Specifically embedding the while condition check inside the loop so this becomes
        -- effectively a do until vs a do while.
        keep_running = not ((end_node and inspect_node == end_node) or (inspect_node.type == 'netman_host'))
        if inspect_node:has_children() then
            -- We shouldn't have to check this as it should be able to be assumed that we have children
            -- since we are searching from inside it. But still, better safe than sorry
            for _, child_id in ipairs(inspect_node:get_child_ids()) do
                if not previous_node or child_id ~= previous_node.id then
                    local child_node = tree:get_node(child_id)
                    if child_node then
                        child_node.extra.cache_skip_node = child_node.skip_node
                        child_node.skip_node = true
                        table.insert(hidden_children, child_node)
                    end
                end
            end
        end
        previous_node = inspect_node
        inspect_node = tree:get_node(inspect_node:get_parent_id())
    end
    local host = previous_node
    if host.type ~= 'netman_host' then
        -- Get the provider so we can store the hidden nodes with it
        host = M.internal.query_node_tree(tree, start_node, 'host')
    end
    if not host then
        -- complain
        log.error("Unable to find host for node focusing, reverting focus changes", {last_checked_node=previous_node, initial_node=start_node})
        for _, child in ipairs(hidden_children) do
            child.skip_node = child.extra.cache_skip_node
            child.extra.cache_skip_node = nil
        end
        return
    end
    if not host.extra.hidden_children then host.extra.hidden_children = {} end
    for _, child in ipairs(hidden_children) do
        host.extra.hidden_children[child.id] = child
    end
    start_node:expand()
    renderer.redraw(state)
    renderer.focus_node(state, start_node.id)
    return true
end

M.internal.enable_search_mode = function(state, search_param, locking_host)
    -- TODO: Figure out a way to make it visually clear how to "leave" search mode
    M.internal.search_locking_host = locking_host.id
    M.internal.search_started_on = state.tree:get_node().id
    M.internal.search_mode_enabled = true
    local search_node = state.tree:get_node(M.constants.ROOT_IDS.NETMAN_SEARCH)
    search_node.skip_node = false
    search_node.name = string.format("Searching For: %s", search_param)
    renderer.redraw(state)
end

M.internal.disable_search_mode = function(state)
    local search_node = state.tree:get_node(M.constants.ROOT_IDS.NETMAN_SEARCH)
    search_node.skip_node = true
    search_node.name = ""
    M.internal.unfocus_path(state, state.tree:get_node(M.internal.search_locking_host))
    if M.internal.search_cache then
        for _, node_id in ipairs(M.internal.search_cache) do
            local node = state.tree:get_node(state.tree:get_node(node_id):get_parent_id())
            -- Expire the parent of the search node
            if node and node.extra then node.extra.expiration = 1 end
        end
    end
    if M.internal.search_started_on then
        renderer.focus_node(state, M.internal.search_started_on)
    end
    M.internal.search_cache = nil
    M.internal.search_started_on = nil
    M.internal.search_locking_host = nil
    M.internal.search_mode_enabled = false
end

M.internal.search_netman = function(state, uri, param)
    assert(state, "No state provided!")
    assert(uri, "No base uri provided!")
    assert(param, "No search param provided!")
    local tree = state.tree
    assert(tree, "No neotree associated with provided state!")
    local host = M.internal.query_node_tree(tree, tree:get_node(uri), 'host')
    if not host then
        -- Complain about not getting a host?
        notify.warn(string.format("Unable to locate netman host for %s", uri))
        return
    end
    M.internal.enable_search_mode(state, param, host)
    M.internal.focus_path(state, tree:get_node(uri))
    local search_results = api.search(uri, param, {search = 'filename', case_sensitive = false})
    if not search_results or not search_results.success or not search_results.data then
        -- IDK, complain?

        return
    end
    local cache_path = {}
    local cache_results = {}
    -- Fetching the "root" node of the host
    -- Instead of iterating over the results, maybe bury the
    -- below logic into a local anon function that we call on ASYNC callback.
    for result_uri, result in pairs(search_results.data) do
        local parent = host
        -- TODO: Search mode should prevent expiration
        for _, parent_details in ipairs(result.ABSOLUTE_PATH) do
            local new_node = cache_path[parent_details.uri] or tree:get_node(parent_details.uri)
            if not new_node then
                local new_node_details =
                {
                    URI = parent_details.uri,
                    NAME = parent_details.name,
                    FIELD_TYPE = 'LINK'
                }
                if parent_details.uri == result_uri then
                    new_node_details = result.METADATA
                end
                new_node = M.internal.create_ui_node(new_node_details)
                M.internal.add_nodes(state, new_node, parent.id, true)
                cache_path[new_node_details.URI] = new_node
            end
            parent = new_node
        end
        table.insert(cache_results, parent.id)
    end
    M.internal.search_cache = cache_results
    renderer.redraw(state)
end

M.search = function(state)
    if M.internal.search_mode_enabled then
        -- We are already in a search, somehow allow for searching the present results????
        return
    end
    local node = state.tree:get_node()
    if node.type == 'netman_provider' then
        notify.warn("Cannot perform search on a provider!")
        return
    end
    -- TODO:
    -- I don't know that this is right. The idea is that
    -- if the node is a directory, we should be able to search it,
    -- however we should also allow for grepping the file....?
    if not node.extra.searchable then
        node = state.tree:get_node(node:get_parent_id())
    end
    local message = "Search Param. Press enter to begin searching"
    local default = ""
    local uri = node.extra.uri
    local callback = function(response)
        M.internal.search_netman(state, uri, response)
    end
    input.input(message, default, callback)
end

--- @param state NeotreeState
---     Whatever the state is that Neotree provides
--- @param nodes table
---     A 1D table of Nodes to create. See https://github.com/nvim-neo-tree/neo-tree.nvim/blob/7c6903b05b13c5d4c3882c896a59e6101cb51ea7/lua/neo-tree/ui/renderer.lua#L1071
---     for details on what these nodes should be
---     NOTE: You can pass a single node to add (outside a 1d table) and we will fix it for you because
---     we're a nice API like that ;)
--- @param parent_id string | Optional
---     Default: nil
---     The id of the parent to add the node to
---     If not provided, we will add to root
--- @param sort_nodes boolean | Optional
---     Default: false
---     If provided, we will sort the nodes after adding the new one(s)
--- @return table
---     Returns the serialized node tree. Useful if you wish to render later
M.internal.add_nodes = function(state, nodes, parent_id, sort_nodes)
    assert(state, "No Neotree state provided")
    assert(nodes, "No node provided to add")
    if #nodes == 0 and next(nodes) then nodes = { nodes } end
    local parent_children = {}
    local serialized_children = nil
    if state.tree then
        -- parent_children = state.tree:get_nodes(parent_id)
        local parent_node = state.tree:get_node(parent_id)
        if parent_node:has_children() then
            for _, child_id in ipairs(parent_node:get_child_ids()) do
                local _child = state.tree:get_node(child_id)
                table.insert(parent_children, _child)
            end
        end
        serialized_children = M.internal.serialize_nodes(state.tree, parent_children)
    end
    -- If we didn't get anything back, we are probably safe to assume we are the only node to display
    if not serialized_children or #serialized_children == 0 then
        serialized_children = nodes
    else
        for _, node in ipairs(nodes) do
            table.insert(serialized_children, node)
        end
    end
    if sort_nodes then
        local unsorted_children = {}
        local children_map = {}
        for _, item in ipairs(serialized_children) do
            table.insert(unsorted_children, item.name)
            children_map[item.name] = item
        end
        local sorted_children = neo_tree_utils.sort_by_tree_display(unsorted_children)
        serialized_children = {}
        for _, child in ipairs(sorted_children) do
            table.insert(serialized_children, children_map[child])
        end
    end
    renderer.show_nodes(serialized_children, state, parent_id)
    return serialized_children
end

--- Returns an array that can be used with renderer.show_nodes to recreate everything at this node (and under)
M.internal.serialize_nodes = function(tree, nodes)
    assert(tree, "No tree provided to serialize nodes!")
    -- Quick short circuit if there is nothing to serialize
    if not nodes or #nodes == 0 and not next(nodes) then return {} end
    -- Wrapping nodes in a 1D array to ensure I can iterate over it
    if #nodes == 0 then nodes = { nodes } end
    local flat_tree = {}
    local queue = {}
    for _, node in ipairs(nodes) do table.insert(queue, node) end
    local head = nil
    local head_node = nil
    while #queue > 0 do
        head = table.remove(queue, 1)
        head_node = tree:get_node(head.id)
        flat_tree[head.id] = head
        if head_node then
            if head_node:has_children() then
                for _, child_id in ipairs(head_node:get_child_ids()) do
                    -- This may not be in the correct order...
                    local new_child = flat_tree[child_id] or M.internal.create_ui_node(tree:get_node(child_id))
                    flat_tree[child_id] = new_child
                    new_child.parent = head.id
                    table.insert(queue, new_child)
                end
            end
        end
        if head.parent and flat_tree[head.parent] then
            if not flat_tree[head.parent].children then flat_tree[head.parent].children = {} end
            table.insert(flat_tree[head.parent].children, head)
        end
    end
    local return_tree = {}
    for _, node in ipairs(nodes) do
        table.insert(return_tree, flat_tree[node.id])
    end
    return return_tree
end

--- Pass this whatever was returned by netman.api.read OR a valid neotree node and we will convert the results
--- into a valid Neotree node constructor (think like python's repr)
--- NOTE: This will **NOT** transfer children. For something more indepth, use M.internal.serialize_nodes
M.internal.create_ui_node = function(data)
    local node = {}
    if data.id then
        -- The data is a neotree node, treat it as such
        node.name = data.name
        node.id = data:get_id()
        node.type = data.type
        node.skip_node = data.skip_node
        node._is_expanded = data:is_expanded()
        if node._is_expanded then
            node.children = {}
        end
        node.extra = {}
        if data.extra then
            for key, value in pairs(data.extra) do
                node.extra[key] = value
            end
        end
    elseif data.URI then
        -- The data is a netman api.read return
        -- -- TODO: Set provider mapping for things like expiration, icons, etc
        -- local icon_map = M.internal.provider_configs[node.extra.provider]
        -- if icon_map then icon_map = icon_map.icon end
        node.name = data.NAME
        node.id = data.URI
        node.type = 'file'
        node._is_expanded = data._is_expanded
        node.extra = {
            -- TODO: We should allow providers to dictate how long the expiration is for an item
            expiration = vim.loop.hrtime() + M.constants.DEFAULT_EXPIRATION_LIMIT,
            uri = data.URI,
            markable = true,
            marked = false,
            searchable = false,
            expandable = false,
            expire_amount = M.constants.DEFAULT_EXPIRATION_LIMIT
        }
        if data.FIELD_TYPE == 'LINK' then
            -- TODO: Allow the API to return what the actual type is for render?
            node.type = 'directory'
            node.children = {}
            node.extra.expandable = true
            node.extra.searchable = true
        end
    else
        log.error("Unable to determine type of node!", data)
    end
    return node
end

M.internal.generate_providers = function()
    local providers = {}
    for _, provider_path in ipairs(api.providers.get_providers()) do
        local status, provider = pcall(require, provider_path)
        if not status or not provider.ui then
            -- Failed to import the provider for some reason
            -- or the provider is not UI ready
            if not provider.ui then
                log.info(string.format("%s is not ui ready, it is missing the ui attribute", provider_path))
            end
            goto continue
        end
        table.insert(providers, {
            -- Provider's (in this context) are unique as they are 
            -- import paths from netman.api
            id = provider_path,
            name = provider.name,
            type = M.constants.TYPES.NETMAN_PROVIDER,
            children = {},
            extra = {
                expandable = true,
                icon = provider.ui.icon or "",
                highlight = provider.ui.highlight or "",
                provider = provider_path,
            }
        })
        ::continue::
    end
    table.sort(providers, M.internal.sorter.ascending)
    return providers
end

M.internal.generate_provider_children = function(provider)
    local hosts = {}
    for _, host in ipairs(api.providers.get_hosts(provider)) do
        local host_details = api.providers.get_host_details(provider, host)
        if not host_details then
            log.warn(string.format("%s did not return any details for %s", provider, host))
            goto continue
        end
        table.insert(hosts, {
            id = host_details.URI,
            name = host_details.NAME,
            type = "netman_host",
            children = {},
            extra = {
                expandable = true,
                state = host_details.STATE,
                last_access = host_details.LAST_ACCESSED,
                provider = provider,
                host = host,
                uri = host_details.URI,
                searchable = true,
                hidden_children = {}
            }
        })
        ::continue::
    end
    table.sort(hosts, M.internal.sorter.ascending)
    return hosts
end

M.internal.generate_node_children = function(state, node, opts)
    assert(state, "No state provided!")
    assert(node, "No node provided!")
    assert(node.extra, "No extra attributes on node!")
    assert(node.extra.uri, "No uri found on node!")
    local uri = node.extra.uri
    opts = opts or {}
    local children = {}
    -- Get the output from netman.api.read
    -- Do stuff with that output?
    local output = api.read(uri)
    if not output then
        log.info(string.format("%s did not return anything on read", uri))
        return nil
    end
    if output.error then
        local _error = output.error
        local message = _error.message
        -- Handle the error?
        -- The error wants us to do a thing
        if _error.callback then
            local default = _error.default or ""
            local parent_id = state.tree:get_node():get_parent_id()
            local callback = function(_)
                local response = _error.callback(_)
                if response.retry then
                    -- Do a retry of ourselves???
                    M.refresh(state, {refresh_only_id=parent_id, auto=true, quiet=true})
                end
            end
            input.input(message, default, callback)
            return nil
        else
            if not opts.ignore_unhandled_errors then
                -- No callback was provided, display the error and move on with our lives
                print(string.format("Unable to read %s, received error %s", uri, message))
                log.warn(string.format("Received error while trying to run read of uri: %s", uri), {error=message})
            end
            return nil
        end
    end
    if output.type == 'FILE' or output.type == 'STREAM' then
        -- Make neo-tree create a buffer for us
        local command = ""
        local open_command = 'read ++edit'
        local event_handler_id = "netman_dummy_file_event"
        if output.type == 'STREAM' then
            command = '0append! ' .. table.concat(output.data) .. command
        else
            command = string.format("%s %s %s", open_command, output.data.local_path, command)
        end
        local dummy_file_open_handler = {
            event = "file_opened",
            id = event_handler_id
        }
        dummy_file_open_handler.handler = function()
            events.unsubscribe(dummy_file_open_handler)
        end
        events.subscribe(dummy_file_open_handler)
        neo_tree_utils.open_file(state, uri)
        return nil
    end
    local unsorted_children = {}
    local children_map = {}
    for _, item in ipairs(output.data) do
        local child = M.internal.create_ui_node(item)
        table.insert(unsorted_children, child.name)
        children_map[child.name] = child
    end
    local sorted_children = neo_tree_utils.sort_by_tree_display(unsorted_children)
    for _, child in ipairs(sorted_children) do
        table.insert(children, children_map[child])
    end
    return children
end

M.navigate = function(state, opts)
    local tree, node, nodes, parent_id, sort_nodes
    opts = opts or {}
    nodes = {}
    -- Check to see if there is even a tree built
    tree = state.tree
    sort_nodes = true
    if not tree or not renderer.window_exists(state) then
        nodes = M.constants.ROOT_CHILDREN
        sort_nodes = false
        goto render
    end
    -- If target_id is provided, we will navigate to that instead of whatever the
    -- tree is currently looking at
    node = tree:get_node(opts.target_id)
    -- Check if the node is the search node
    if node.id == M.constants.ROOT_IDS.NETMAN_SEARCH then
        M.internal.disable_search_mode(state)
        return
    end

    -- collapse the node
    if node:is_expanded() then
        node:collapse()
        renderer.redraw(state)
        return
    end
    -- Check to see if the node has children and its expired
    if node:has_children() then
        if M.internal.search_mode_enabled or not node.extra.expiration or node.extra.expiration > vim.loop.hrtime() then
            node:expand()
            renderer.redraw(state)
            return
        else
            -- The parent has expired, clear out its children so it can be refreshed
            for _, child_id in ipairs(node:get_child_ids()) do
                tree:remove_node(child_id)
            end
            node.extra.expiration = vim.loop.hrtime() + node.extra.expire_amount
        end
    end
    parent_id = node.id
    if node.id == M.constants.ROOT_IDS.NETMAN_PROVIDERS then
        nodes = M.internal.generate_providers()
    elseif node.type == M.constants.TYPES.NETMAN_PROVIDER then
        -- They selected a provider node, we need to populate it
        nodes = M.internal.generate_provider_children(node.extra.provider)
    else
        -- They selected a node provided by a provider, get its data
        nodes = M.internal.generate_node_children(state, node)
    end
    ::render::
    if nodes then
        M.internal.add_nodes(state, nodes, parent_id, sort_nodes)
        renderer.focus_node(state, parent_id)
    end
end

M.internal.refresh_provider = function(state, provider, opts)
    assert(state, "No state provided")
    assert(provider, "No provider provided for refresh")
    opts = opts or {}
    local tree = state.tree
    local current_hosts = {}
    local provider_node = tree:get_node(provider)
    assert(provider_node, string.format("No node associated with provider: %s", provider))
    if not opts.quiet then
        notify.info(string.format("Refreshing %s", provider))
    end
    if provider_node:has_children() then
        for _, child_id in ipairs(provider_node:get_child_ids()) do
            local child = tree:get_node(child_id)
            if child and child:is_expanded() then
                local __ = M.internal.serialize_nodes(tree, child)[1]
                if __ then
                    current_hosts[child_id] = __.children or {}
                end
            end
        end
    end
    local new_hosts = M.internal.generate_provider_children(provider)
    for _, host in ipairs(new_hosts) do
        local children = current_hosts[host.id]
        if children then
            host._is_expanded = true
            host.children = children
        end
    end
    renderer.show_nodes(new_hosts, state, provider)
end

M.internal.refresh_uri = function(state, uri, opts)
    assert(state, "No state provided")
    assert(uri, "No uri to refresh")
    opts = opts or {}
    local tree = state.tree
    local node = tree:get_node(uri)
    assert(node, string.format("%s is not currently displayed anywhere, can't refresh!", uri))
    node = M.internal.create_ui_node(node)
    assert(node, string.format("Unable to serialize Neotree node for %s", uri))

    if not opts.quiet then
        notify.info(string.format("Refreshing %s", uri))
    end
    local walk_stack = { node }
    local flat_tree = {}
    local head = nil
    while #walk_stack > 0 do
        head = table.remove(walk_stack, 1)
        local head_node = tree:get_node(head.id)
        flat_tree[head.id] = head
        if head_node and head_node:is_expanded() then
            if head_node:has_children() then
                for _, child_id in ipairs(head_node:get_child_ids()) do
                    local new_child = flat_tree[child_id]
                    if not new_child then
                        M.internal.create_ui_node(tree:get_node(child_id))
                        flat_tree[child_id] = new_child
                    end
                    table.insert(walk_stack, new_child)
                end
            end
            local children = api.read(head.id)
            if not children then
                -- Something horrendous happened and we got nil back.
                log.error(string.format("Nothing returned by api.read for %s!", uri))
                notify.error("Unexpected Netman error. Please check logs for details. :h Nmlogs")
                return
            end
            if not children.success then
                local message = string.format("Unknown error while reading from api for %s", uri)
                if children.error then
                    if type(children.error) == 'string' then
                        message = children.error
                    else
                        message = children.error.message
                    end
                end
                notify.warn(message)
                return
            end
            if children.data then
                local unsorted_children = {}
                local children_map = {}
                if not head.children then head.children = {} end
                for _, child_data in ipairs(children.data) do
                    local child = flat_tree[child_data.URI]
                    if not child then
                        child = M.internal.create_ui_node(child_data)
                        flat_tree[child.id] = child
                    end
                    children_map[child.name] = child
                    table.insert(unsorted_children, child.name)
                end
                local sorted_children = neo_tree_utils.sort_by_tree_display(unsorted_children)
                for _, child_name in ipairs(sorted_children) do
                    -- Got weird nil error while inserting _something_
                    table.insert(head.children, children_map[child_name])
                end
            end
        end
    end
    for _, child_id in ipairs(tree:get_node(uri):get_child_ids()) do
        -- Remove all current children of this uri
        tree:remove_node(child_id)
    end

    renderer.show_nodes(flat_tree[uri].children, state, uri)
end

M.refresh = function(state, opts)
    local node
    opts = opts or {}
    -- Per NUI doc, if we pass nil into `get_node`,
    -- we get the current node we are looking at. Thus
    -- we can abuse the fact that tables return nil for
    -- missing keys
    node = state.tree:get_node(opts.refresh_only_id)
    local cache_type = node.type
    if not node then
        -- Complain that there is no node selected for refresh
        log.warn("No node selected for refresh")
        return
    end
    if node.extra.uri then
        -- This is a node in one of the providers.
        if not node.extra.expandable then
            -- The selected node is not a "directory" type and thus shouldn't be
            -- refreshed. Get its parent
            node = state.tree:get_node(node:get_parent_id())
            -- Redoing this since the node type will be incorrect unless
            -- we refetch it
            cache_type = node.type
        end
        if not opts.quiet then
            node.type = 'netman_refresh'
            renderer.redraw(state)
        end
        M.internal.refresh_uri(state, node.extra.uri, opts)
    elseif node.type == M.constants.TYPES.NETMAN_PROVIDER then
        -- The user requested a full provider refresh.
        if not opts.quiet then
            node.type = 'netman_refresh'
            renderer.redraw(state)
        end
        M.internal.refresh_provider(state, node.extra.provider, opts)
    else
        -- The user selected one of the bookmark nodes, those cannot be refreshed. Just ignore the
        -- action
    end
    node.type = cache_type
    if not opts.quiet then
        renderer.redraw(state)
    end
    if not opts.auto then
        -- Quiet means that we wont redraw or focus the node in question.
        renderer.focus_node(state, node.id)
    end
end

M.internal.add_item_to_node = function(state, node, item)
    if node.type == 'file' then
        node = state.tree:get_node(node:get_parent_id())
    end
    local uri = string.format("%s", node.extra.uri)
    -- Stripping off the trailing `/` as we will be adding our own later
    local children = {}
    local child = nil
    local parent = node:get_id()
    for _ in item:gmatch('([^/]+)') do
        table.insert(children, _)
    end
    local is_item_dir = item:sub(-1, -1) == '/'
    child = nil
    local walk_uris = {}
    while #children > 0 do
        child = table.remove(children, 1)
        local new_uri = string.format('%s%s/', uri, child)
        -- No children left, strip off the trailing / unless its supposed to be there
        if #children == 0 and not is_item_dir then new_uri = new_uri:sub(1, -2) end
        local write_status = api.write(nil, new_uri)
        if not write_status.success then
            notify.error(write_status.error.message)
            return false
        end
        uri = write_status.uri
        table.insert(walk_uris, uri)
    end
    M.refresh(state, {refresh_only_id = parent, quiet = true, auto = true})
    for _, _uri in ipairs(walk_uris) do
        M.navigate(state, {target_id = _uri})
    end
    return true
end

M.create_node = function(state, opts)
    local tree, node
    opts = opts or {}
    tree = state.tree
    node = tree:get_node()
    if node.type == 'netman_provider' then
        print("Adding new hosts to a provider isn't supported. Yet... 👀")
        return
    end
    local message = "Enter name of new file/directory. End the name in / to make it a directory"
    if opts.force_dir then
        message = "Enter name of new directory"
    end
    local callback = function(response)
        if opts.force_dir and response:sub(-1, -1) ~= '/' then
            response = string.format("%s/", response)
        end
        -- Check to see if node is a directory. If not, get its parent
        if node.type ~= 'directory' then tree:get_node(node:get_parent_id()) end
        notify.info(string.format("Attempting to create %s", response))
        local success = M.internal.add_item_to_node(state, node, response)
        if success then
            notify.info(string.format("Successfully created %s", response))
        end
    end
    -- Check if the node is active before trying to add to it
    -- Prompt for new item name
    -- Create new item in netman.api with the provider ui and parent path
    -- Refresh the parent only
    -- Navigate to the item
    input.input(message, "", callback)
end

M.setup = function(neo_tree_config)

end

return M
