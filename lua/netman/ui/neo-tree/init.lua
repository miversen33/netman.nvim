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
            NETMAN_RECENTS = "netman_recents",
            NETMAN_FAVORITES = "netman_favorites",
            NETMAN_PROVIDERS = "netman_providers"
        },
    },
    internal = {
        sorter = {},
        -- Where we will keep track of nodes that have been
        -- marked for cut/copy/delete/open/etc
        marked_nodes = {},
        -- Used for temporarily removing nodes from view
        node_cache = {}
    }
}
-- Breaking this out into its own assignment because it has references to M
M.constants.ROOT_CHILDREN =
{
    {
        id = M.constants.ROOT_IDS.NETMAN_RECENTS,
        name = 'Recents',
        type = "netman_bookmark",
        children = {},
        extra = {
            icon = "",
            highlight = "",
            provider = "",
        }
    },
    {
        id = M.constants.ROOT_IDS.NETMAN_FAVORITES,
        name = "Favorites",
        type = "netman_bookmark",
        children = {},
        extra = {
            icon = "",
            highlight = "",
            provider = "",
        }
    },
    {
        id = M.constants.ROOT_IDS.NETMAN_PROVIDERS,
        name = "Providers",
        type = "netman_bookmark",
        children = {},
        extra = {
            -- TODO: Idk, pick a better icon?
            icon = "",
            highlight = "",
            provider = "",
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

-- --- Renames the selected or target node
-- --- @param state NeotreeState
-- --- @param target_node_id string
-- ---     The node to target for deletion. If not provided, will use the
-- ---     currently selected node in state
-- M.rename_node = function(state, target_node_id)
--     local tree, node, current_uri, parent_uri, parent_id
--     tree = state.tree
--     node = tree:get_node(target_node_id)
--     if not node.extra then
--         log.warn(string.format("%s says its a netman node but its lyin", node.name))
--         return
--     end
--     if node.type == 'netman_provider' then
--         notify.info(string.format("Providers cannot be renamed at this time"))
--         return
--     end
--     if node.type == 'netman_host' then
--         notify.info(string.format("Hosts cannot be renamed at this time"))
--         return
--     end
--     current_uri = node.extra.uri
--     parent_id = node:get_parent_id()
--     parent_uri = tree:get_node(parent_id).extra.uri
--
--     local message = string.format("Rename %s", node.name)
--     local default = ""
--     local callback = function(response)
--         if not response then return end
--         local new_uri = string.format("%s%s", parent_uri, response)
--         local success = M.internal.rename(current_uri, new_uri)
--         if not success then
--             notify.warn(string.format("Unable to move %s to %s. Please check netman logs for more details", current_uri, new_uri))
--             return
--         end
--         M.refresh(state, {refresh_only_id=parent_id, auto=true})
--         -- Rename any buffers that currently have the old uri as their name
--         for _, buffer_number in ipairs(vim.api.nvim_list_bufs()) do
--             if vim.api.nvim_buf_get_name(buffer_number) == current_uri then
--                 vim.api.nvim_buf_set_name(buffer_number, new_uri)
--             end
--         end
--     end
--     input.input(message, default, callback)
-- end

-- --- Marks a node for later use.
-- --- @param node NuiTreeNode
-- --- @param mark string
-- ---     Valid marks
-- ---     - cut
-- ---     - delete
-- ---     - copy
-- ---     - open
-- --- @return table
-- ---     Returns a table with the following key,value pairs
-- ---     - success : boolean
-- ---     - error   : string | Optional
-- ---         - If returned, the message/reason for failure
-- M.mark_node = function(node, mark)
--     assert(M.constants.MARK[mark], string.format("Invalid Mark %s", mark))
--     if not node.extra or not node.extra.markable then
--         return {
--             success = false,
--             error = string.format('%s is not a moveable node!', node.name)
--         }
--     end
--     local marked_nodes = M.internal.marked_nodes[mark] or {}
--     table.insert(marked_nodes, node:get_id())
--     M.internal.marked_nodes[mark] = marked_nodes
--     return { success = true }
-- end

-- --- Process marked nodes
-- --- @param state NeotreeState
-- --- @param target_marks table/nil
-- --- @return nil
-- M.process_marked_nodes = function(state, target_marks)
--     if not target_marks then
--         target_marks = {}
--         -- Adding all marks to process
--         for _, value in pairs(M.constants.MARK) do
--             table.insert(target_marks, value)
--         end
--     end
--     -- validating the target marks
--     for _, mark in ipairs(target_marks) do
--         -- Jump to end of loop if there is nothing for us to do with this mark
--         if not M.internal.marked_nodes[mark] then goto continue end
--         assert(M.constants.MARK[mark], string.format("Invalid Target Mark: %s", mark))
--         local nodes = {}
--         local tree = state.tree
--         local target_node = tree:get_node()
--         for _, node_id in ipairs(M.internal.marked_nodes[mark]) do
--             local node = tree:get_node(node_id)
--             table.insert(nodes, node)
--         end
--         if mark == M.constants.MARK.cut and #nodes > 0 then
--             M.move_nodes(state, nodes, target_node)
--         end
--         -- Clearing out the marked nodes for this mark
--         M.internal.marked_nodes[mark] = nil
--         ::continue::
--     end
-- end

-- -- Breaking this out into its own assignment because it has references to M- Clears out the marked nodes
-- --- @param target_marks table
-- ---     If provided, only clears out marks for the provided targets
-- ---     Valid marks can be found in @see mark_node
-- M.clear_marked_nodes = function(target_marks)
--     if not target_marks then
--         target_marks = {}
--         -- Adding all marks to process
--         for _, value in pairs(M.constants.MARK) do
--             table.insert(target_marks, value)
--         end
--     end
--     -- validating the target marks
--     for _, mark in ipairs(target_marks) do
--         assert(M.constants.MARK[mark], string.format("Invalid Target Mark: %s", mark))
--         M.internal.marked_nodes[mark] = {}
--     end
-- end


-- M.move_node = function(state)
--     M.clear_marked_nodes()
--     local node = state.tree:get_node()
--     local status = M.mark_node(node, M.constants.MARK.cut)
--     if status.success then
--         notify.info(string.format("Selected %s for cut", node.name))
--     else
--         notify.warn(status.error)
--     end
-- end

-- M.move_nodes = function(state, nodes, target_node)
--     local uris = {}
--     local parents = {}
--     local bailout = true
--     for _, node in ipairs(nodes) do
--         table.insert(uris, node.extra.uri)
--         parents[node:get_parent_id()] = 1
--         bailout = false
--     end
--     if bailout then
--         return
--     end
--     if target_node.type == 'netman_provider' then
--         notify.info(string.format("Cant move target into a provider"))
--         return
--     end
--     if target_node.type ~= 'directory' and target_node.type ~= 'netman_host' then target_node = state.tree:get_node(target_node:get_parent_id()) end
--     local target_uri = target_node.extra.uri
--     local success = api.move(uris, target_uri)
--     if success then
--         for parent, _ in pairs(parents) do
--             M.refresh(state, {refresh_only_id=parent, auto=true})
--         end
--         M.refresh(state, {refresh_only_id=target_node:get_id(), auto=true})
--     end
--     -- TODO: Highlight target?
-- end

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

--- Deletes the selected or target node
--- @param state NeotreeState
--- @param target_node_id string
---     The node to target for deletion. If not provided, will use the
---     currently selected node in state
M.delete_node = function(state, target_node_id)
    -- TODO: Do we also delete the buffer if its open????
    local tree, node, node_name, parent_id
    tree = state.tree
    node = tree:get_node(target_node_id)
    node_name = node.name
    parent_id = node:get_parent_id()
    if node.type == 'netman_provider' then
        print("Deleting providers isn't supported. Please uninstall the provider instead")
        return
    end
    if node.type == 'netman_host' then
        print("Removing hosts isn't supported. Yet... 👀")
        return
    end
    -- Get confirmation...
    local message = string.format("Are you sure you want to delete %s [y/N]", node_name)
    local default = "N"
    local callback = function(response)
        if not response:match('^[yY]') then
            log.info(string.format("Did not receive confirmation of delete. Bailing out of deletion of %s", node_name))
            return
        end
        local success = M.internal.delete_item(node.extra.uri)
        if not success then
            notify.warn(string.format("Unable to delete %s. Received error, check netman logs for details!", node_name))
            return
        end
        -- Idk how we plan on doing refresh yet
        M.refresh(state, {refresh_only_id=parent_id, quiet=true})
    end
    input.input(message, default, callback)
end

M.delete_nodes = function(state, nodes)
    for _, node_id in ipairs(nodes) do
        M.delete_node(state, node_id)
    end
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

    assert(state, "No state provided")
    assert(uri, "No uri to refresh")
    local tree = state.tree
    local node = tree:get_node(uri)
    -- TODO: Change the type of the URI to netman_refresh?
    assert(node, string.format("%s is not currently displayed anywhere, can't refresh!", uri))
    node = M.internal.create_ui_node(node)
    assert(node, string.format("Unable to serialize Neotree node for %s", uri))

    notify.info(string.format("Refreshing %s", uri))
    local walk_stack = { node }
    local process_stack = {}
    local flat_tree = {}
    while #walk_stack > 0 do
        local head = table.remove(walk_stack, 1)
        local head_node = tree:get_node(head.id)
        if head_node and head_node:is_expanded() then
            if head_node:has_children() then
                for _, child_id in ipairs(head_node:get_child_ids()) do
                    local new_child = M.internal.create_ui_node(tree:get_node(child_id))
                    table.insert(walk_stack, new_child)
                end
            end
            table.insert(process_stack, head)
        end
        flat_tree[head.id] = head
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
                table.insert(head.children, children_map[child_name])
            end
        end
    end
    renderer.show_nodes(flat_tree[uri].children, state, uri)
end

M.setup = function(neo_tree_config)

end

return M
