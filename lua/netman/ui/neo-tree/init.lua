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
-- TODO: Figure out a way to make a constant variable????

-- Sorts nodes in ascending order
M.internal.sorter.ascending = function(a, b) return a.name < b.name end

-- Sorts nodes in descending order
M.internal.sorter.descending = function(a, b) return a.name > b.name end

M.internal.generate_root_children = function()
    -- Root Tree
    return {
        {
            id = 'netman_recents',
            name = 'Recents',
            type = "netman_bookmark",
            extra = {
                icon = "",
                highlight = "",
                provider = "",
            }
        },
        {
            id = "netman_favorites",
            name = "Favorites",
            type = "netman_bookmark",
            extra = {
                icon = "",
                highlight = "",
                provider = "",
            }
        },
        {
            id = "netman_providers",
            name = "Providers",
            type = "netman_bookmark",
            extra = {
                -- TODO: Idk, pick a better icon?
                icon = "",
                highlight = "",
                provider = "",
            }
        },
        {
            -- There is an attribute called `skip_node`, I wonder if we should use that instead?
            id = "netman_search",
            name = "Search",
            type = "netman_bookmark",
            skip_node = true,
            extra = {
                icon = "",
                highlight = "",
                provider = "",
            }
        }
    }
end

M.internal.get_providers = function()
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
            type = "netman_provider",
            extra = {
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

M.internal.get_provider_children = function(provider)
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
            extra = {
                state = host_details.STATE,
                last_access = host_details.LAST_ACCESSED,
                provider = provider,
                host = host,
                uri = host_details.URI,
                searchable = true
            }
        })
        ::continue::
    end
    table.sort(hosts, M.internal.sorter.ascending)
    return hosts
end

M.internal.get_uri_children = function(state, uri, opts)
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
                    M.refresh(state, {refresh_only_id=parent_id, auto=true})
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
        return children
    end
    local unsorted_children = {}
    local children_map = {}
    for _, item in ipairs(output.data) do
        local child = {
            id = item.URI,
            name = item.NAME,
            extra = {
                uri = item.URI,
                markable = true,
                searchable = false
            }
        }
        if item.FIELD_TYPE == 'LINK' then
            child.type = 'directory'
            child.extra.searchable = true
        else
            child.type = 'file'
        end
        table.insert(unsorted_children, child.name)
        children_map[child.name] = child
    end
    local sorted_children = neo_tree_utils.sort_by_tree_display(unsorted_children)
    for _, child in ipairs(sorted_children) do
        table.insert(children, children_map[child])
    end
    return children
end

M.internal.generate_node_children = function(state, node, opts)
    opts = opts or {}
    local children = {}
    if not node then
        -- No node was provided, assume we want the root providers
        children = M.internal.generate_root_children()
        -- children = M.internal.get_providers()
    elseif node.id == 'netman_providers' then
        children = M.internal.get_providers()
    elseif node.type == "netman_provider" then
        if not node.extra.provider then
            -- SCREAM!
            log.error(string.format("Node %s says its a provider but doesn't have a provider. How tf????", node.name), {node=node})
            return children
        end
        children = M.internal.get_provider_children(node.extra.provider, opts)
    else
        if not node.extra.uri then
            -- SCREAM!
            log.error(string.format("Node %s says its a netman node, but has no URI. How tf????", node.name), {node=node})
            return children
        end
        children = M.internal.get_uri_children(state, node.extra.uri, opts)
    end
    return children
end

M.refresh = function(state, opts)
    local refresh_stack, return_stack, tree, head, children
    opts = opts or {}
    -- If provided, will force a global refresh of everything, including the providers
    -- Available options are
    -- do_all: boolean
    -- refresh_only_id: string
    -- Create an empty process stack
    refresh_stack= {}
    -- Create an empty return stack
    return_stack  = {}
    if not state.tree then
        -- How did you call refresh without a tree already rendered?
        -- Should probably call navigate with no tree instead
        return M.navigate(state)
    end
    tree = state.tree
    local message = ''
    if opts.do_all then
        -- Iterate over the "root nodes" (providers) and add them to the refresh stack
        for _, child in ipairs(tree:get_nodes('netman_providers')) do
            table.insert(refresh_stack, child)
        end
        message = "Running full refresh of all providers"
    elseif opts.refresh_only_id then
        -- We are going to start our refresh at this node, regardless of what node
        -- we are currently looking at
        -- NOTE: Not really sure why but lua shits the bed if you move the
        -- function call into the table.insert statement so 🤷
        local _ = state.tree:get_node(opts.refresh_only_id)
        table.insert(refresh_stack, _)
        message = string.format("Running Targetted Refresh of %s", opts.refresh_only_id)
    else
        -- Add the current node found at state.tree:get_node() to the process stack
        -- NOTE: Not really sure why but lua shits the bed if you move the
        -- function call into the table.insert statement so 🤷
        local _ = state.tree:get_node()
        -- If the refresh is being ran on a file, refresh the parent directory instead
        if _.type ~= 'directory' then _ = state.tree:get_node(_:get_parent_id()) end
        table.insert(refresh_stack, _)
        message = string.format("Running full refresh on %s", _.name)
    end
    -- Auto will be passed by anything inside this file. External calls to refresh will
    -- notify the user that a refresh was triggered
    if not opts.auto then
        notify.info(message)
    end
    local generate_node_children_opts = {
        ignore_unhandled_errors = opts.auto or false
    }
    while(#refresh_stack> 0) do
        -- - While there are things in the process stack
        head = table.remove(refresh_stack, 1)
        local head_id = head:get_id()
        -- - Check if any of current node's children are expanded. If so, add those children to the tail of the process stack
        -- NOTE: Might be able to call tree:get_nodes(head:get_id()) instead...?
        for _, child_id in ipairs(head:get_child_ids()) do
            local child_node = tree:get_node(child_id)
            -- Quick escape of logic if somehow the node doesn't exist
            if not child_node then goto continue end

            if child_node:is_expanded() then
                -- The node is expanded, add it to the refresh stack
                table.insert(refresh_stack, child_node)
            end
            ::continue::
        end
        -- - Generate the nodes new children (assume all nodes will always have the same ID)
        children = M.internal.generate_node_children(state, head, generate_node_children_opts)
        if children and type(children) == 'table' then
            table.insert(return_stack, {children=children, parent_id=head_id})
        else
            log.warn("Received invalid children from generation of head", {head=head, children=children})
        end
        -- Checking if children were returned, and there is more than 0
        -- Lua empty tables still pass truthy checks
        -- - Add the children (and applicable parent id) to the return stack
    end
    -- While there are things in the return stack
    while(#return_stack > 0) do
        -- - Add each item to the renderer via (renderer.show_nodes), ensuring that if a parent id was provided, we add the items under that id
        head = table.remove(return_stack, 1)
        children = head.children
        local parent = tree:get_node(head.parent_id)
        -- Check if the parent node still exists. If it doesn't we wont try to render our cached info on its children
        if parent then
            renderer.show_nodes(children, state, head.parent_id)
            if head.parent_id then
                -- Get the node that was just rendered and expand it  (it wouldn't be in this list if it wasn't)
                tree:get_node(head.parent_id):expand()
            end
        end
    end
end

M.navigate = function(state, opts)
    local tree, node, nodes, parent_id
    opts = opts or {}
    -- Check to see if there is even a tree built
    tree = state.tree
    if not tree or not renderer.window_exists(state) then
        -- Somehow there was no providers rendered.
        nodes = M.internal.generate_node_children(state)
        parent_id = nil
    else
        if opts.target_id then
            node = tree:get_node(opts.target_id)
        else
            node = tree:get_node()
        end
        if not node or not node.extra then
            log.warn("Node doesn't exist or is missing the extra attribute", {node=node, opts=opts})
            return
        end
        if node.id ~= 'netman_search' then
            -- Hide netman search
            state.tree:get_node('netman_search').skip_node = true
        end
        if node:is_expanded() then
            node:collapse()
            renderer.redraw(state)
            return
        end
        if node.id == 'netman_search' then
            -- Nothing for us to do here, you tried to expand a node that you shouldn't
            -- be able to expand.
            return
        end
        nodes = M.internal.generate_node_children(state, node)
        parent_id = node:get_id()
    end
    renderer.show_nodes(nodes, state, parent_id)
end

M.internal.add_item_to_node = function(state, node, item)
    log.debug(string.format("Trying to add item to node"), {node=node, item=item})
    if node.type == 'file' then
        node = state.tree:get_node(node:get_parent_id())
    end
    local uri = string.format("%s", node.extra.uri)
    local head_child = nil
    local children = {}
    local tail_child = nil
    local parent_id = node:get_id()
    for child in item:gmatch('([^/]+)') do
        table.insert(children, child)
    end
    if item:sub(-1, -1) ~= '/' then
    -- the last child is a file, we need to create it seperately from the above children
        tail_child = table.remove(children, #children)
    end
    -- We iterate over the children creating each one on its own because not all
    -- providers might be able to create all the directories at once 😥
    while(#children > 0) do
        head_child = table.remove(children, 1)
        uri = string.format("%s%s/", uri, head_child)
        local write_status = api.write(nil, uri)
        if not write_status.success then
            notify.error(write_status.error.message)
            return
        end
        M.refresh(state, {refresh_only_id=parent_id, auto=true})
        parent_id = uri
    end
    if tail_child then
        uri = string.format("%s%s", uri, tail_child)
        local write_status = api.write(nil, uri)
        if not write_status.success then
            -- IDK, complain?
            notify.error(write_status.error.message)
            return
        end
        uri = write_status.uri
        M.refresh(state, {refresh_only_id=parent_id, auto=true})
        M.navigate(state, {target_id=uri})
    end
end

M.add_node = function(state, opts)
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
        M.internal.add_item_to_node(state, node, response)
    end
    -- Check if the node is active before trying to add to it
    -- Prompt for new item name
    -- Create new item in netman.api with the provider ui and parent path
    -- Refresh the parent only
    -- Navigate to the item
    input.input(message, "", callback)
end

M.internal.delete_item = function(uri)
    local status, _error = pcall(api.delete, uri)
    if not status then
        log.warn(string.format("Received error while trying to delete uri %s", uri), {error=_error})
        return false
    end
    return true
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
    log.debug(string.format("Deleting Node %s with parent id %s", node_name, parent_id))
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
        M.refresh(state, {refresh_only_id=parent_id, auto=true})
    end
    input.input(message, default, callback)
end

M.internal.rename = function(old_uri, new_uri)
    return api.move(old_uri, new_uri)
end

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
        local success = M.internal.rename(current_uri, new_uri)
        if not success then
            notify.warn(string.format("Unable to move %s to %s. Please check netman logs for more details", current_uri, new_uri))
            return
        end
        M.refresh(state, {refresh_only_id=parent_id, auto=true})
        -- Rename any buffers that currently have the old uri as their name
        for _, buffer_number in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_get_name(buffer_number) == current_uri then
                vim.api.nvim_buf_set_name(buffer_number, new_uri)
            end
        end
    end
    input.input(message, default, callback)
end

--- Marks a node for later use.
--- @param node NuiTreeNode
--- @param mark string
---     Valid marks
---     - cut
---     - delete
---     - copy
---     - open
--- @return table
---     Returns a table with the following key,value pairs
---     - success : boolean
---     - error   : string | Optional
---         - If returned, the message/reason for failure
M.mark_node = function(node, mark)
    assert(M.constants.MARK[mark], string.format("Invalid Mark %s", mark))
    if not node.extra or not node.extra.markable then
        return {
            success = false,
            error = string.format('%s is not a moveable node!', node.name)
        }
    end
    local marked_nodes = M.internal.marked_nodes[mark] or {}
    table.insert(marked_nodes, node:get_id())
    M.internal.marked_nodes[mark] = marked_nodes
    return { success = true }
end

--- Process marked nodes
--- @param state NeotreeState
--- @param target_marks table/nil
--- @return nil
M.process_marked_nodes = function(state, target_marks)
    if not target_marks then
        target_marks = {}
        -- Adding all marks to process
        for _, value in pairs(M.constants.MARK) do
            table.insert(target_marks, value)
        end
    end
    -- validating the target marks
    for _, mark in ipairs(target_marks) do
        -- Jump to end of loop if there is nothing for us to do with this mark
        if not M.internal.marked_nodes[mark] then goto continue end
        assert(M.constants.MARK[mark], string.format("Invalid Target Mark: %s", mark))
        local nodes = {}
        local tree = state.tree
        local target_node = tree:get_node()
        for _, node_id in ipairs(M.internal.marked_nodes[mark]) do
            local node = tree:get_node(node_id)
            table.insert(nodes, node)
        end
        if mark == M.constants.MARK.cut and #nodes > 0 then
            M.move_nodes(state, nodes, target_node)
        end
        -- Clearing out the marked nodes for this mark
        M.internal.marked_nodes[mark] = nil
        ::continue::
    end
end

--- Clears out the marked nodes
--- @param target_marks table
---     If provided, only clears out marks for the provided targets
---     Valid marks can be found in @see mark_node
M.clear_marked_nodes = function(target_marks)
    if not target_marks then
        target_marks = {}
        -- Adding all marks to process
        for _, value in pairs(M.constants.MARK) do
            table.insert(target_marks, value)
        end
    end
    -- validating the target marks
    for _, mark in ipairs(target_marks) do
        assert(M.constants.MARK[mark], string.format("Invalid Target Mark: %s", mark))
        M.internal.marked_nodes[mark] = {}
    end
end


M.move_node = function(state)
    M.clear_marked_nodes()
    local node = state.tree:get_node()
    local status = M.mark_node(node, M.constants.MARK.cut)
    if status.success then
        notify.info(string.format("Selected %s for cut", node.name))
    else
        notify.warn(status.error)
    end
end

M.move_nodes = function(state, nodes, target_node)
    local uris = {}
    local parents = {}
    local bailout = true
    for _, node in ipairs(nodes) do
        table.insert(uris, node.extra.uri)
        parents[node:get_parent_id()] = 1
        bailout = false
    end
    if bailout then
        return
    end
    if target_node.type == 'netman_provider' then
        notify.info(string.format("Cant move target into a provider"))
        return
    end
    if target_node.type ~= 'directory' and target_node.type ~= 'netman_host' then target_node = state.tree:get_node(target_node:get_parent_id()) end
    local target_uri = target_node.extra.uri
    local success = api.move(uris, target_uri)
    if success then
        for parent, _ in pairs(parents) do
            M.refresh(state, {refresh_only_id=parent, auto=true})
        end
        M.refresh(state, {refresh_only_id=target_node:get_id(), auto=true})
    end
    -- TODO: Highlight target?
end

M.copy_nodes = function(state, nodes, target_node)
    
end

M.open_nodes = function(state, nodes)

end

M.delete_nodes = function(state, nodes)
    for _, node_id in ipairs(nodes) do
        M.delete_node(state, node_id)
    end
end

M.internal.hide_root_nodes = function(state)
    for _, node in ipairs(state.tree:get_nodes()) do
        node.extra.previous_state = node:is_expanded()
        node:collapse()
    end
end

M.internal.show_root_nodes = function(state)
    for _, node in ipairs(state.tree:get_nodes()) do
        if node.extra.previous_state then node:expand() end
    end
end

M.search = function(state)
    local node = state.tree:get_node()
    if node.type == 'netman_provider' then
        notify.warn("Cannot perform search on a provider!")
        return
    end
    -- I don't know that this is right. The idea is that
    -- if the node is a directory, we should be able to search it,
    -- however we should also allow for grepping the file....?
    if not node.extra.searchable then
        node = state.tree:get_node(node:get_parent_id())
    end
    local message = "Search Param"
    local default = ""
    local uri = node.extra.uri
    -- Must be positive integer, there should be no file depth that is 100000 deep. Yaaaa jank
    local depth = 100000
    local callback = function(response)
        -- Hide nodes?
        M.internal.hide_root_nodes(state)
        state.tree:get_node('netman_search').skip_node = false
        renderer.redraw(state)
        -- NEED TO STAT THE OUTPUT SO WE KNOW HOW TO DISPLAY IT
        local stdout = {}
        local stdout_callback = function(item)
            if not item or not item.ABSOLUTE_PATH then return end
            log.debug(item)
            -- This hardcode makes it so we expect data to come back in unix compliant paths...
            local parent = stdout
            for item_node in item.ABSOLUTE_PATH:gmatch('[^/]+') do
                local child_node = {
                    id = "find://" .. item_node.URI,
                    name = item_node.NAME,
                    type = 'file',
                    extra = {
                        uri = item.URI,
                    }
                }
                if item_node ~= item.NAME then
                    child_node.type = 'directory'
                end
                local new_parent = nil
                for _, child in ipairs(parent) do
                    if child.name == item_node then
                        new_parent = child
                    end
                end
                if not new_parent then new_parent = parent end
                if not new_parent.children then new_parent.children = {} end
                table.insert(new_parent.children, child_node)
                -- This may cause some issues but it _shouldn't_
                parent = new_parent
            end
            -- local first_line = nil
            -- local last_line = nil
            -- for line in output:gmatch('[^\r\n]+') do
                -- log.debug("Line: " .. line)
                -- if not first_line then first_line = line end
                -- last_line = line
                -- log.debug(string.format("Processing %s", line))
            -- local parent = stdout
            -- for part in output:gmatch('[^/]+') do
            --     if part:sub(-1, -1) ~= '/' then
            --         table.insert(parent, part)
            --     else
            --         parent[part] = {}
            --     end
            --     parent = parent[part]
            -- end
            -- log.debug({first_line = first_line, last_line = last_line})
        end
        local exit_callback = function()
            log.debug("Complete Search Tree", stdout)
        end
        log.debug(
            api.search(
                uri,
                response,
                {
                    max_depth       = depth,
                    search          = 'filename',
                    case_sensitive  = false,
                    async           = true,
                    stdout_callback = stdout_callback,
                    exit_callback   = exit_callback
                }
            )
        )
    end
    input.input(message, default, callback)
end

M.setup = function(neo_tree_config)

end

return M
