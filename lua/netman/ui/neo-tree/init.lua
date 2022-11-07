--This file should have all functions that are in the public api and either set
--or read the state of this source.

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
    internal = {
        sorter = {}
    }
}

-- Sorts nodes in ascending order
M.internal.sorter.ascending = function(a, b) return a.name < b.name end

-- Sorts nodes in descending order
M.internal.sorter.descending = function(a, b) return a.name > b.name end

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
                provider = provider_path
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
                uri = host_details.URI
            }
        })
        ::continue::
    end
    table.sort(hosts, M.internal.sorter.ascending)
    return hosts
end

M.internal.get_uri_children = function(state, uri)
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
                    M.refresh(state, {refresh_only_id=parent_id})
                end
            end
            input.input(message, default, callback)
            return nil
        else
            -- No callback was provided, display the error and move on with our lives
            print(string.format("Unable to read %s, received error", message))
            log.warn(string.format("Received error while trying to run read of uri: %s", uri), {error=message})
            return nil
        end
    end
    if output.type == 'FILE' or output.type == 'STREAM' then
        -- Make neo-tree create a buffer for us
        local command = " | set nomodified | filetype detect"
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
            require("netman.tools.utils").render_command_and_clean_buffer(command)
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
                uri = item.URI
            }
        }
        if item.FIELD_TYPE == 'LINK' then
            child.type = 'directory'
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

M.internal.generate_node_children = function(state, node)
    local children = {}
    if not node then
        -- No node was provided, assume we want the root providers
        children = M.internal.get_providers()
    elseif node.type == "netman_provider" then
        if not node.extra.provider then
            -- SCREAM!
            log.error(string.format("Node %s says its a provider but doesn't have a provider. How tf????", node.name), {node=node})
            return children
        end
        children = M.internal.get_provider_children(node.extra.provider)
    else
        if not node.extra.uri then
            -- SCREAM!
           log.error(string.format("Node %s says its a netman node, but has no URI. How tf????", node.name), {node=node})
           return children
        end
        children = M.internal.get_uri_children(state, node.extra.uri)
    end
    return children
end

-- BUG: When refresh is ran on a file, it is opened. Probably not great
-- Need a way to indicate that we only want to refresh a certain id
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
    if opts.do_all then
        -- Iterate over the "root nodes" (providers) and add them to the refresh stack
        for _, child in ipairs(tree:get_nodes()) do
            table.insert(refresh_stack, child)
        end
        log.debug("Running full refresh of all providers")
    elseif opts.refresh_only_id then
        -- We are going to start our refresh at this node, regardless of what node
        -- we are currently looking at
        -- NOTE: Not really sure why but lua shits the bed if you move the
        -- function call into the table.insert statement so 🤷
        local _ = state.tree:get_node(opts.refresh_only_id)
        table.insert(refresh_stack, _)
        log.debug(string.format("Running Targetted Refresh of %s", opts.refresh_only_id))
    else
        -- Add the current node found at state.tree:get_node() to the process stack
        -- NOTE: Not really sure why but lua shits the bed if you move the
        -- function call into the table.insert statement so 🤷
        local _ = state.tree:get_node()
        table.insert(refresh_stack, _)
        log.debug(string.format("Running full refresh on %s", _.name))
    end
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
        children = M.internal.generate_node_children(state, head)
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
    if not tree then
        -- Somehow there was no providers rendered.
        nodes = M.internal.generate_node_children(state)
        parent_id = nil
    else
        if opts.target_id then
            node = tree:get_node(opts.target_id)
        else
            node = tree:get_node()
        end
        if not node.extra then
            log.warn(string.format("Node %s doesn't have any extra attributes, not dealing with this shit today", node.name))
            return
        end
        if node:is_expanded() then
            node:collapse()
            renderer.redraw(state)
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
        api.write(nil, uri)
        M.refresh(state, {refresh_only_id=parent_id})
        parent_id = uri
    end
    if tail_child then
        uri = string.format("%s%s", uri, tail_child)
        api.write(nil, uri)
        M.refresh(state, {refresh_only_id=parent_id})
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

M.delete_node = function(state)
    local tree, node, node_name, parent_id
    tree = state.tree
    node = tree:get_node()
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
        M.refresh(state, {refresh_only_id=parent_id})
    end
    input.input(message, default, callback)
end

M.internal.rename = function(old_uri, new_uri)
    return api.move(old_uri, new_uri)
end

M.rename_node = function(state)
    -- Get the name to rename to
    local tree, node, current_uri, parent_uri, parent_id
    tree = state.tree
    node = tree:get_node()
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
        M.refresh(state, {refresh_only_id=parent_id})
    end
    input.input(message, default, callback)
end

M.move_node = function(state)

    notify.warn("Move is not currently supported!")
    return
end

M.setup = function(neo_tree_config)

end

return M
