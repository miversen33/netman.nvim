-- There be a weird bug where the cursor will sometimes jump to the top of the buffer.
-- No idea why. Strange things be happening me boi

local netman_utils = require("netman.tools.utils")
local netman_api = require("netman.api")
local netman_types = require("netman.tools.options").api.READ_TYPE
local netman_errors = require("netman.tools.options").api.ERRORS
local netman_type_attributes = require("netman.tools.options").api.ATTRIBUTES
local netman_ui = require("netman.ui")
local logger = netman_ui.get_logger()

local neo_tree_events = require("neo-tree.events")
local neo_tree_utils = require("neo-tree.utils")
local neo_tree_renderer = require("neo-tree.ui.renderer")
local neo_tree_defaults = require("netman.ui.neo-tree.defaults")
local neo_tree_input = require("neo-tree.ui.inputs")

local M = {}
M.internal = {}
M.constants = {
    TYPES = {
        NETMAN_BOOKMARK = "netman_bookmark",
        NETMAN_PROVIDER = "netman_provider",
        NETMAN_HOST     = "netman_host",
        NETMAN_EXPLORE  = "directory",
        NETMAN_FILE     = "file",
        NETMAN_STREAM   = "stream"
    },
    ATTRIBUTE_MAP = {
        [netman_type_attributes.DESTINATION] = "file",
        [netman_type_attributes.LINK] = "directory"
    },
    ROOT_IDS = {
        NETMAN_STOP      = "netman_stop",
        NETMAN_RECENTS   = "netman_recents",
        NETMAN_FAVORITES = "netman_favorites",
        NETMAN_PROVIDERS = "netman_providers",
    },
    TIMEOUTS = {
        NETMAN_REFRESH_LOOP_TIMEOUT = 10000
    },
    ACTIONS = { 'copy', 'move' }
}

M.name = "remote"
M.display_name = 'ﯱ Remote'
M.default_config = neo_tree_defaults

M.internal.marked_nodes = {}
M.internal.internally_marked_nodes = {}
M.internal.mark_action = nil
M.internal.sorter = {}

-- Sorts nodes in ascending order
M.internal.sorter.ascending = function(a, b) return a.name < b.name end

-- Sorts nodes in descending order
M.internal.sorter.descending = function(a, b) return a.name > b.name end

M.internal.current_process_handle = nil
M.internal.node_map = {}
M.internal.navigate_map = {}
M.internal.refresh_map  = {}
M.internal._root_nodes = {
    -- {
    --     name = "Stop",
    --     id = M.constants.ROOT_IDS.NETMAN_STOP,
    --     type = M.constants.TYPES.NETMAN_STOP,
    --     parent_id = nil,
    --     extra = {
    --         icon = "",
    --         ignore_sort = true,
    --         -- skip = true
    --     }
    -- },
    -- {
    --     name = "Recents",
    --     id = M.constants.ROOT_IDS.NETMAN_RECENTS,
    --     type = M.constants.TYPES.NETMAN_BOOKMARK,
    --     parent_id = nil,
    --     extra = {
    --         icon = "",
    --         ignore_sort = true,
    --     }
    -- },
    -- {
    --     id = M.constants.ROOT_IDS.NETMAN_FAVORITES,
    --     name = "Favorites",
    --     type = M.constants.TYPES.NETMAN_BOOKMARK,
    --     parent_id = nil,
    --     extra = {
    --         icon = "",
    --         ignore_sort = true
    --     }
    -- },
    {
        name = "Providers",
        id = M.constants.ROOT_IDS.NETMAN_PROVIDERS,
        type = M.constants.TYPES.NETMAN_BOOKMARK,
        parent_id = nil,
        extra = {
            icon = "",
            skip = false,
            ignore_sort = true
        },
    },
}

M._root = {}

----------------- \/ Basic Helper Functions

local function get_mapped_node(nui_node)
    return nui_node and M.internal.node_map[nui_node:get_id()] or nil
end

local function create_node(node_details, parent_id)
    -- Probably should validate we have good data to create
    -- a nui node
    local parent_node = parent_id and M.internal.node_map[parent_id]
    local node = {
        name = node_details.name,
        id = node_details.id,
        extra = node_details.extra or {},
        type = node_details.type,
        parent_id = parent_id,
        navigate = node_details.navigate or M.internal.navigate_map[node_details.id] or M.internal.navigate_map[node_details.type],
        refresh = node_details.refresh or M.internal.refresh_map[node_details.id] or M.internal.refresh_map[node_details.type],
    }
    if not node.id then
        logger.warn("Node was created with no id!", node_details)
        return
    end

    if M.internal.node_map[node.id] then
        logger.debugf("Found matching node for (id: %s, name: %s) so using that instead!", node.id, node.name)
        if M.internal.node_map[node.id].parent_id ~= parent_id then
            logger.warn("Requested new node has a different parent than existing node!")
        end
        return
    end

    if not node.name then
        logger.warn("Node was created with no name!", node_details)
        return
    end
    if not node.type then
        logger.info("Node was created with no type! Setting type to file", node_details)
        node.type = M.constants.TYPES.NETMAN_FILE
    end
    local nui_node = {
        id = node.id,
        name = node.name,
        type = node.type,
        _is_expanded = node_details.expanded,
        extra = node_details.extra or {}
    }
    if node_details.children then
        -- Iterate through the children and create them too
        node.children = {}
        local nui_children = {}
        for _, raw_child_node in ipairs(node_details.children) do
            local child_node = create_node(raw_child_node, node.id)
            table.insert(node.children, child_node.id)
            table.insert(nui_children, child_node.nui_node)
        end
        nui_node.children = nui_children
    end
    if parent_node then
        if not parent_node.children then
            -- This is ick, but I suppose we should
            -- put a guardrail in place for adding kids when
            -- the parent isn't ready for them
            parent_node.children = {}
        end
        table.insert(parent_node.children, node.id)
    end
    nui_node.extra.parent = node.parent_id
    node.extra.nui_node = nui_node
    M.internal.node_map[node.id] = node
    return node
end

local function tree_to_nui(in_tree, do_sort)
    -- BUG: There is some weirdness in how expanded nodes are being rendered now...
    -- Occasionally this will determine that a closed node should be open
    -- TODO: I hate that this is recursive...
    local tree = {}
    -- Kinda nasty but a little thing that will be tripped by any node
    -- that has an extra.no_sort flag set
    local ignore_sort = false
    for _, leaf_id in ipairs(in_tree) do
        local leaf = M.internal.node_map[leaf_id]
        if leaf and not leaf.extra.skip then
            if leaf.extra.ignore_sort then
                ignore_sort = true
            end
            local node = leaf.extra.nui_node
            if leaf.children and #leaf.children > 0 then
                node.children = tree_to_nui(leaf.children, do_sort)
            end
            table.insert(tree, node)
        end
    end
    if do_sort and not ignore_sort then
        -- We should probably use the 
        -- neo_tree_utils.sort_by_tree_display function instead
        table.sort(tree, M.internal.sorter.ascending)
    end
    return tree
end

local function navigate_root_provider(nui_node)
    local node = get_mapped_node(nui_node)
    if nui_node:is_expanded() then
        nui_node:collapse()
        node.extra.nui_node._is_expanded = false
    else
        nui_node:expand()
        node.extra.nui_node._is_expanded = true
        if node.children and #node.children > 0 then
            return nil, true
        end
        -- TODO: Add some sort of auto refresh?
        local raw_providers = netman_ui.get_providers()
        local providers = {}
        for name, provider_details in pairs(raw_providers) do
            local provider_node = {
                id = provider_details.path,
                name = name,
                type = M.constants.TYPES.NETMAN_PROVIDER,
                children = {},
                extra = {
                    icon = provider_details.ui.icon,
                    highlight = provider_details.ui.highlight,
                    path = provider_details.path,
                    hosts_func = provider_details.hosts
                }
            }
            create_node(provider_node, node.id)
            table.insert(providers, provider_node.id)
        end
        return tree_to_nui(providers, true)
    end
    return nil, true
end

local function navigate_file(nui_node)
    -- Do nothing. Don't use this
end

local function navigate_directory(nui_node)
    local node = get_mapped_node(nui_node)
    if nui_node:is_expanded() then
        nui_node:collapse()
        node.extra.nui_node._is_expanded = false

    else
        nui_node:expand()
        node.extra.nui_node._is_expanded = true
        -- Get content for the node
    end
    return nil, true
end
----------------- /\ Basic Helper Functions

----------------- \/ Provider Helper Functions
local function navigate_provider(nui_node)
    -- Collapse the node if its expanded
    local node = get_mapped_node(nui_node)
    if nui_node:is_expanded() then
        nui_node:collapse()
        node.extra.nui_node._is_expanded = false
    else
        -- Get content for the node
        local hosts = {}
        local raw_hosts = node.extra.hosts_func()
        for host_name, host_state_func in pairs(raw_hosts) do
            local raw_host_details = host_state_func()
            local host_details = {
                id = raw_host_details.id,
                name = host_name,
                type = M.constants.TYPES.NETMAN_HOST,
                children = {},
                extra = {
                    -- Maybe make this pass a callable?
                    state = raw_host_details.state,
                    uri = raw_host_details.uri,
                    entrypoint = raw_host_details.entrypoint,
                    last_access = raw_host_details.last_loaded,
                }
            }
            create_node(host_details, nui_node:get_id())
            table.insert(hosts, host_details.id)
        end
        nui_node:expand()
        node.extra.nui_node._is_expanded = true
        return tree_to_nui(hosts, true)
    end
    return nil, true
end

local function refresh_provider(nui_node)
    -- TODO
    local node = M.internal.node_map[nui_node.id]
    logger.infof("Refreshing Node: %s", node.name)
end
----------------- /\ Provider Helper Functions

----------------- \/ URI Helper Functions

local function open_directory(directory, parent_id, dont_render)
    local parent_node = M.internal.node_map[parent_id]
    for _, raw_node in ipairs(directory) do
        local node = {
            id = raw_node.URI,
            name = raw_node.NAME,
            type = M.constants.ATTRIBUTE_MAP[raw_node.FIELD_TYPE],
            children = raw_node.FIELD_TYPE == "LINK" and {} or nil,
            extra = {
                uri = raw_node.URI,
                metadata = raw_node.METADATA,
                markable = true
            }
        }
        create_node(node, parent_id)
    end
    if not dont_render then
        local children = parent_node.children
        return tree_to_nui(children, true)
    end
end

local function open_stream(stream)

end

local function open_uri(node, link_callback, dest_callback, message_callback)
    -- We should really be checking to see if the node has
    -- an entrypoint and calling that
    -- We should temporarily map something globally to cancel the read?
    -- Or add something to the top of the tree to "stop" the handle?
    local _data = {}
    local _type = nil
    local uri = node.extra.uri
    local render_tree = nil
    logger.tracef("Opening Node: %s", uri)
    M.internal.current_process_handle = netman_api.read(uri, {}, function(data, complete)
        if data and not data.success then
            -- There was a failure of some kind!
            if data.message then
                logger.debug("Received message:", data.message)
                return message_callback(data.message)
            end
            logger.info("Received potentially unhandled result from netman api", data)
        end
        if not _type and data and data.type then
            _type = data.type
        end
        if not _type then
            -- Complain or something?
            -- Should we still save the data?
            logger.warn("Unable to match type to response!")
            return
        end
        if not data.success then
            -- We should really be complaining
            logger.warn("DEAD!", data)
            return
        end
        if _type == netman_types.EXPLORE then
            if data then
                for _, item in ipairs(data.data) do
                    table.insert(_data, item)
                end
            end
            if complete then
                render_tree = open_directory(_data, node.id)
                link_callback(render_tree)
            end
        elseif _type == netman_types.FILE then
            dest_callback(uri)
        else
            return open_stream(data.data)
        end
    end)
end

local function navigate_uri(nui_node, state, complete_callback)
    -- TODO: We need something to prevent accidentally executing "multiple" reads at once
    local node = get_mapped_node(nui_node)
    if nui_node:is_expanded() then
        -- Collapse the node and return
        nui_node:collapse()
        node.extra.nui_node._is_expanded = false
        return nil, true
    end
    nui_node:expand()
    node.extra.nui_node._is_expanded = true
    if nui_node:has_children() then
        return nil, true
    end
    local link_callback = function(render_tree)
        vim.defer_fn(function()
            logger.debug("Deferred opening of link")
            M.internal.finish_navigate(state, render_tree, node.id, false, complete_callback)
        end, 1)
    end
    local dest_callback = function(uri)
        vim.defer_fn(function()
            logger.debug("Deferred opening of destination")
            neo_tree_renderer.redraw(state)
            neo_tree_utils.open_file(state, uri)
            if complete_callback then complete_callback() end
        end, 1)
    end
    local message_callback = function(message)
        logger.trace("Message:", message)
        if message.message then
            -- HANDLE WEIRD RESPONSES FROM PROVIDERS HERE
            logger.info("Received error:", message.message)
            if message.error == netman_errors.ITEM_DOESNT_EXIST then
                local uri = message.uri
                local local_name = nui_node.name
                logger.warnnf("%s no longer exists!", local_name)
                logger.infof("%s is not available on remote resource anymore", uri)
                M.internal.node_map[uri] = nil
                state.tree:remove_node(uri)
                neo_tree_renderer.redraw(state)
            elseif message.error == netman_errors.PERMISSION_ERROR then
                local warning = message.message or "Permission Denied"
                logger.warnn(warning)
            else
                if message.callback and type(message.callback) == 'function' and message.message then
                    local _message = message.message
                    local default = message.default and message.default or ""
                    local _callback = message.callback
                    logger.trace("Attempting to prompt the user for information?")
                    neo_tree_input.input(_message, default, _callback)
                    return
                else
                    logger.warnn("Error received from provider:", message.message)
                end
            end
        end
    end
    local handle = open_uri(node, link_callback, dest_callback, message_callback)
    -- Returning "true" so we can update to show the "refresh"/"loading" icon
    return nil, true
end

local function delete_uri(nui_nodes, state, complete_callback, internal_only)
    local tree = state.tree
    local uris = {}
    local redraw_nodes = {}
    local head = nil
    while #nui_nodes > 0 do
        head = table.remove(nui_nodes)
        table.insert(redraw_nodes, head:get_parent_id())
        table.insert(uris, head:get_id())
    end
    local process_map = {}
    for _, uri in ipairs(uris) do
        -- Preloading the process_map with _something
        -- This is to prevent premature post processing
        -- by the deleter because it thinks it's done
        -- when it's not.
        process_map[uri] = 1
    end
    local starter_complete = false
    local process_results = function(uri, results, complete, st_complete)
        if st_complete then
            starter_complete = true
        end
        if uri then
            process_map[uri] = nil
            local count = 0
            for _, _ in pairs(process_map) do count = count + 1 end
            logger.trace2f("Removing process handle for %s. There are currently %s remaining processes", uri, count)
        end
        if uri and ((results and results.success) or internal_only) then
            local next_nui_node = tree:get_node(uri)
            local next_node = get_mapped_node(next_nui_node)

            logger.trace2(string.format("Removing children from %s", uri), next_node, next_nui_node)
            if next_node and next_node.children then
                local clear_children = {}
                local proc_node = next_node
                while proc_node do
                    if proc_node.children and #proc_node.children > 0 then
                        for _, child_id in ipairs(proc_node.children) do
                            table.insert(clear_children, M.internal.node_map[child_id])
                            M.internal.node_map[child_id] = nil
                        end
                        proc_node.children = {}
                    end
                    proc_node = table.remove(clear_children, 1)
                end
            end
            if next_nui_node then
                local parent = M.internal.node_map[next_nui_node:get_parent_id()]
                local child_index = nil
                for i, child_id in ipairs(parent.children) do
                    if child_id == uri then
                        child_index = i
                        break
                    end
                end
                if child_index then
                    table.remove(parent.children, child_index)
                end
                tree:remove_node(uri)
            end
            if M.internal.node_map[uri] then
                M.internal.node_map[uri] = nil
            end
        end
        if results and not results.success then
            local nui_node = tree:get_node(uri)
            local mapped_node = get_mapped_node(nui_node)
            mapped_node.extra.state = 'ERROR'
            nui_node.extra.error = true
            logger.error(string.format("Received failure when trying to delete %s", uri), results)
            logger.warnnf("Removal of %s failed. Please check `:Nmlogs` for details", uri)
        end
        if complete and not next(process_map) and starter_complete then
            logger.tracef("Remote removal complete. Marking %s for auto refresh")
            local render_trees = {}
            for _, parent_id in ipairs(redraw_nodes) do
                local parent_node = M.internal.node_map[parent_id]
                if parent_node then
                    render_trees[parent_id] = tree_to_nui(parent_node.children, true)
                end
            end
            vim.defer_fn(function()
                local focus_node = tree:get_node()
                local focus_id = focus_node and focus_node:get_id()
                for parent_id, render_tree in pairs(render_trees) do
                    neo_tree_renderer.show_nodes(render_tree, state, parent_id)
                end
                if focus_id and tree:get_node(focus_id) then
                    neo_tree_renderer.focus_node(state, focus_id)
                end
                if complete_callback then complete_callback() end
            end, 1)
        end
    end
    for _, uri in ipairs(uris) do
        if internal_only then
            process_results(uri)
        else
            local handle = netman_api.delete(
                uri,
                function(results, complete)
                    process_results(uri, results, complete)
                end
            )
            if process_map[uri] then
                process_map[uri] = handle
            end
        end

    end
    process_results(nil, nil, true, true)
end

-- Fuck multinode refresh. I swear to anything and everything that is possibly holy
-- that if I have to fucking touch this stupid fucking piece of shit function ever again
-- after I get it fucking working, I will rain hell onto hell itself. There is no torture
-- worse than trying to figure out abstract fucking depths in a tree, when you
-- don't even know if the remote version of the fucking node exists anymore.
--
-- Fuck you refresh, I hope you die in a fire hotter than anything known to man
local function refresh_uri(nui_nodes, state, complete_callback, focused_node_id)
    local tree = state.tree
    focused_node_id = focused_node_id or tree:get_node():get_id()
    local children = { }
    local used_children = { }
    local mapped_parents = { }
    local refreshed_nodes = {}
    local expanded_nodes = { }
    local head = nil
    local child_node = nil
    local redraw_nodes = {}
    -- Preloading children. Probably poo that we iterate this twice...
    for _, node in ipairs(nui_nodes) do
        table.insert(children, node:get_id())
        table.insert(redraw_nodes, node)
        used_children[node:get_id()] = true
    end
    while #nui_nodes > 0 do
        head = table.remove(nui_nodes)
        local head_id = head:get_id()
        local parent_id = head:get_parent_id()
        local _ = head_id
        local p = head
        local path = {}
        -- Get node path for each node we are potentially scanning. Use
        -- this later to make a relatively minimal set of redraw calls to neo-tree
        while p.type ~= M.constants.TYPES.NETMAN_PROVIDER do
            table.insert(path, 1, p.id)
            p = tree:get_node(p:get_parent_id())
        end
        -- Marking the current node as being refreshed so it can
        -- be visually seen
        if not mapped_parents[parent_id] then
            mapped_parents[parent_id] = {}
        end
        mapped_parents[parent_id][head_id] = true
        table.insert(refreshed_nodes, head_id)
        head.extra.refresh = true
        if head:is_expanded() then
            table.insert(expanded_nodes, head_id)
            if not used_children[head_id] then
                table.insert(children, head_id)
                used_children[head_id] = true
            end
            local _ = head
            for _, child_id in ipairs(head:get_child_ids()) do
                child_node = tree:get_node(child_id)
                table.insert(nui_nodes, child_node)
            end
        end
    end
    if #children <= 0 then
        -- I guess we don't need to refresh?
        logger.info("Unable to find any nodes to refresh. Yes, that includes the one you chose to refresh. I don't know, don't shoot the messenger")
        return
    end
    table.sort(redraw_nodes, function(a, b) return a.level < b.level end)
    -- For some reason this redraw doesn't actually reflect in the editor in time to be seen before
    -- we overwrite it. There doesn't appear to be anything we can do about this
    -- as even putting a sleep after the redraw doesn't give the expected result. So I guess
    -- we will have to opt for some thing else...
    neo_tree_renderer.redraw(state)
    logger.debugf("Refreshing %s nodes", #children)
    local next_node = nil
    local next_uri = nil
    local refresher = nil
    local fetched_node_children = {}
    refresher = function(results, complete, start)
        if results and not results.success then
            if results.message and results.message.error then
                -- Gracefully handle the error
                logger.infof("Received Error `%s`", results.message.error)
                if results.message.error == netman_errors.ITEM_DOESNT_EXIST then
                    -- Probably should notify the user that this node was removed?
                    -- Remove the parent node and return
                    M.internal.node_map[results.message.uri] = nil
                    if tree:get_node(results.message.uri) then
                        tree:remove_node(results.message.uri)
                    end
                    -- return
                end
            end
            -- We should really be complaining
            -- logger.warn("Unhandled error returned on refresh!", results)
            -- return
        end

        if results and results.data then
            for _, item in ipairs(results.data) do
                mapped_parents[next_uri][item.URI] = true
                table.insert(fetched_node_children, item)
            end
        end
        if complete then
            logger.debug(string.format("Adding Children to %s", next_uri), fetched_node_children)
            open_directory(fetched_node_children, next_uri, true)
            return refresher(nil, nil, true)
        end
        if start then
            fetched_node_children = {}
            next_uri = table.remove(children, 1)
            next_node = M.internal.node_map[next_uri]
            -- Check to see if there are any more URIs to process
            -- IE, we are dun
            if not next_uri then
                -- TODO: There is probably a better way to iterate through everything...
                for _, id in ipairs(expanded_nodes) do
                    if not M.internal.node_map[id] then goto continue end
                    M.internal.node_map[id].extra.nui_node._is_expanded = true
                    M.internal.node_map[id].extra.refresh = false
                    ::continue::
                end
                for _, id in ipairs(refreshed_nodes) do
                    if not M.internal.node_map[id] then goto continue end
                    M.internal.node_map[id].extra.refresh = false
                    ::continue::
                end
                for id, _ in pairs(M.internal.marked_nodes) do
                    if not M.internal.node_map[id] then goto continue end
                    M.internal.node_map[id].extra.marked = false
                    M.internal.node_map[id].extra.refresh = false
                    ::continue::
                end
                M.internal.marked_nodes = {}
                for id, _ in pairs(M.internal.internally_marked_nodes) do
                    if not M.internal.node_map[id] then goto continue end
                    M.internal.node_map[id].extra.marked = false
                    M.internal.node_map[id].extra.refresh = false
                    ::continue::
                end
                M.internal.internally_marked_nodes = {}
                local render_trees = {}
                for _, redraw_node in ipairs(redraw_nodes) do
                    local redraw_id = redraw_node:get_id()
                    if not M.internal.node_map[redraw_id] then goto continue end
                    local render_tree = tree_to_nui(M.internal.node_map[redraw_id].children, true)
                    render_trees[redraw_id] = render_tree
                    ::continue::
                end
                vim.defer_fn(function()
                    for id, render_tree in pairs(render_trees) do
                        neo_tree_renderer.show_nodes(render_tree, state, id)
                    end
                    local _ = tree:get_node(focused_node_id)
                    if _ then
                        neo_tree_renderer.focus_node(state, focused_node_id)
                    end
                    if complete_callback then complete_callback() end
                end, 1)
                return
            end
            mapped_parents[next_uri] = {}
            local start_refresh = function()
                M.internal.current_process_handle = netman_api.read(next_uri, {}, refresher)
            end
            local next_node_children = {}
            if next_node and next_node.children then
                for _, child_id in ipairs(next_node.children) do
                    _ = tree:get_node(child_id)
                    if _ then
                        table.insert(next_node_children, _)
                    end
                end
            end
            if #next_node_children > 0 then
                return delete_uri(next_node_children, state, start_refresh, true)
            end
            -- if next_nui_node and next_nui_node:has_children() then
            --     logger.warnf("There were orphaned children on node `%s`. Removing them now", next_uri)
            --     for _, child_id in ipairs(next_nui_node:get_child_ids()) do
            --         delete_uri()
            --         logger.debugf("Removing %s from tree", child_id)
            --         tree:remove_node(child_id)
            --     end
            -- end
            start_refresh()
        end
    end
    refresher(nil, nil, true)
end

local function add_uri(state, new_name, opts, complete_callback)
    opts = opts or {}
    local tree = state.tree
    -- Eventually we want this to be something that can be provided by the provider
    local path_sep = "/"
    local matcher = string.format("([^%s]+)", path_sep)
    local current_node = opts.target_node or state.tree:get_node()
    local current_node_uri = current_node:get_id()
    local path = {}
    local new_path = nil
    local iter_path = current_node_uri
    if iter_path:match(string.format("%s$", path_sep)) then
        iter_path = iter_path:sub(1, iter_path:len() - path_sep:len())
    end
    for item in new_name:gmatch(matcher) do
        new_path = string.format("%s%s%s%s", iter_path, path_sep, item, path_sep)
        table.insert(path, new_path)
        -- Strip off the trailing path separator as it is going to be added each time we create this
        iter_path = new_path:sub(1, new_path:len() - path_sep:len())
    end
    -- Basically, the item was specified to be a "link" and we weren't told to force 
    -- it to be one
    if not new_name:match(string.format("%s$", path_sep)) and not opts.force_link then
        local modified_last_item = path[#path]
        modified_last_item = modified_last_item:sub(1, modified_last_item:len() - path_sep:len())
        path[#path] = modified_last_item
    end
    -- Asynchronously create each item in path
    -- and then refresh the original node
    local path_map = {}
    local process_map = {}
    local starter_complete = false
    local navigate_to_new_node = nil
    navigate_to_new_node = function()
        local head_path = table.remove(path, 1)
        if not head_path then
            -- We are done
            if complete_callback then complete_callback() end
            return
        end
        local mapped_head_path = path_map[head_path]
        local head_node = tree:get_node(mapped_head_path)
        if head_node.type == 'directory' then
            -- Open the node
            local nui_node = tree:get_node(head_path)
            navigate_uri(nui_node, state, navigate_to_new_node)
        else
            -- focus the node
            -- maybe also open it?
            neo_tree_renderer.focus_node(state, head_path)
        end
    end

    local process_result = function(uri, data, complete, st_complete)
        if st_complete then
            starter_complete = true
        end
        if data and data.success then
            logger.trace2f("Mapping %s to precalculated uri: %s", data.uri, uri)
            path_map[uri] = data.uri
        end
        if uri then
            process_map[uri] = nil
            local count = 0
            for _, _ in pairs(process_map) do count = count + 1 end
            logger.trace2f("Removing process handle for %s. There are currently %s remaining processes", uri, count)
        end
        if complete and not next(process_map) and starter_complete then
            -- Nothing else do to, dun!
            logger.tracef("Remote creation complete, marking %s for auto refresh", current_node_uri)
            M.internal.internally_marked_nodes[current_node_uri] = 1
            M.refresh(state, navigate_to_new_node)
        end
    end
    for _, uri in ipairs(path) do
        -- Preloading the process_map with _something_
        -- This is to prevent premature post processing
        -- by the writer because it thinks it's done
        -- when its not
        process_map[uri] = 1
    end
    logger.trace("Preloaded the write queue", process_map)
    for _, uri in ipairs(path) do
        local handle =
            netman_api.write(
                uri,
                nil,
                nil,
                function(data, complete)
                    process_result(uri, data, complete)
                end
            )
        -- Because the underlying write request may still be synchronous,
        -- even if we ask it to be async, we need to check to see
        -- if the process has already been resolved. IE, was the 
        -- process ran synchronously? If so, then there wont be anything
        -- in the map and there is no reason to save the handle
        if process_map[uri] then
            process_map[uri] = handle
        end
    end
    process_result(nil, nil, true, true)
end

----------------- /\ URI Helper Functions

function M.internal.render_tree(state)
    local selected_node = state.tree:get_node()
    local mapped_node = get_mapped_node(selected_node)
end

function M.internal.generate_tree(state)
    return tree_to_nui(M._root, true)

end

function M.internal.finish_navigate(state, render_tree, render_parent, do_redraw_only, complete_callback)
    if do_redraw_only then
        neo_tree_renderer.redraw(state)
    elseif render_tree then
        -- Purge children?
        local message = "Rendering new tree"
        if render_parent then
            message = string.format("%s under %s", message, render_parent)
        end
        neo_tree_renderer.show_nodes(render_tree, state, render_parent)
    end
    if complete_callback then complete_callback() end
end

function M.add(state, opts, callback)
    opts = opts or {}
    local tree = state.tree
    if not tree then
        logger.warn("I have no idea what you expect me to add a node to bucko...")
        return
    end
    local target_node = tree:get_node()
    while target_node.type == M.constants.TYPES.NETMAN_FILE or target_node.type == M.constants.TYPES.NETMAN_STREAM do
        -- Get node path for each node we are potentially scanning. Use
        -- this later to make a relatively minimal set of redraw calls to neo-tree
        target_node = tree:get_node(target_node:get_parent_id())
    end
    opts.target_node = target_node
    -- Get the parent directory for target if the current node is a file
    local force_dir = opts.force_dir
    -- Request confirmation before delete
    local process_new_node_name = function(response)
        add_uri(state, response, opts, callback)
    end
    local message = "New Node Name"
    if not force_dir then
        -- TODO: Indicate the proper path sep based on the provider
        message = message .. " Add / at the end to specify the node is a directory"
    end
    neo_tree_input.input(message, "", process_new_node_name)
end

function M.refresh(state, callback)
    local tree = state.tree
    if not tree then
        -- Complain because somehow we are refreshing without a tree to refersh
        logger.warn("I have no idea what you expect me to refresh bucko...")
        return
    end
    local raw_target_nodes = { }
    -- The system said to refresh these nodes. Ignore
    -- actually marked nodes
    if next(M.internal.internally_marked_nodes) then
        logger.trace2("Processing internally marked nodes for refresh")
        raw_target_nodes = {}
        for id, _ in pairs(M.internal.internally_marked_nodes) do
            table.insert(raw_target_nodes, id)
        end
        M.internal.internally_marked_nodes = {}
    elseif next(M.internal.marked_nodes) then
        logger.trace2("Processing externally marked nodes for refresh")
        raw_target_nodes = {}
        for id, _ in pairs(M.internal.marked_nodes) do
            table.insert(raw_target_nodes, id)
        end
    else
        logger.trace2("Processing refresh for single node")
        raw_target_nodes = { tree:get_node():get_id() }
        M.internal.internally_marked_nodes[raw_target_nodes[1]] = true
    end
    local target_nodes = {}
    for _, target_node in ipairs(raw_target_nodes) do
        if type(target_node) == 'string' then
            target_node = tree:get_node(target_node)
        end
        if target_node.type == M.constants.TYPES.NETMAN_BOOKMARK then
            logger.debugn("Refreshing Bookmarks is not supported. Stop it")
            goto continue
        end
        if target_node.type == M.constants.TYPES.NETMAN_PROVIDER then
            logger.infon("Refreshing Providers is not yet implemented")
            goto continue
        end
        if target_node.type ~= M.constants.TYPES.NETMAN_EXPLORE and target_node.type ~= M.constants.TYPES.NETMAN_HOST then
            logger.debugf("Selected node (%s) is not refreshable, reaching up a level", target_node:get_id())
            -- Grab the parent and check again
            target_node = tree:get_node(target_node:get_parent_id())
        end
        table.insert(target_nodes, target_node)
        ::continue::
    end
    refresh_uri(target_nodes, state, callback)
end

function M.delete(state, confirmed, callback)
    -- Confirm before deletion
    local tree = state.tree
    if not tree then
        -- Complain because somehow we are deleting without any nodes available to delete
        logger.warn("I have no idea what you expect me to delete bucko...")
        return
    end
    local raw_target_nodes = { tree:get_node():get_id() }
    local confirmation_message = "Are you sure you want to delete this node?"
    if next(M.internal.marked_nodes) then
        confirmation_message = nil
        -- Explicitly only delete marked nodes if there are any marked nodes
        raw_target_nodes = { }
        for id, _ in pairs(M.internal.marked_nodes) do
            table.insert(raw_target_nodes, id)
        end
    end
    local target_nodes = {}
    -- TODO: Consider adding a `deletable` attribute to 
    -- the node.extra and check for that instead
    for _, target_node in ipairs(raw_target_nodes) do
        logger.trace("Processing delete request for", target_node)
        if type(target_node) == 'string' then
            target_node = tree:get_node(target_node)
        end
        if target_node.type == M.constants.TYPES.NETMAN_BOOKMARK then
            logger.info("Deleting Bookmarks is not supported yet.")
            goto continue
        end
        if target_node.type == M.constants.TYPES.NETMAN_PROVIDER then
            logger.warn("Deleting Providers is not yet implemented. Stop it")
            goto continue
        end
        if target_node.type == M.constants.TYPES.NETMAN_STOP then
            logger.warn("Deleting Stop is not a thing. Stop it")
            goto continue
        end
        table.insert(target_nodes, target_node)
        ::continue::
    end
    if #target_nodes == 0 then
        -- There is nothing valid to delete
        return
    end
    if not confirmation_message then
        confirmation_message = string.format("Are you sure you want to delete %s nodes?", #target_nodes)
    end
    if not confirmed then
        -- Request confirmation before delete
        local process_confirmation = function(do_delete)
            if do_delete then
                M.delete(state, true, callback)
            end
        end
        neo_tree_input.confirm(confirmation_message, process_confirmation)
    else
        local redraw = delete_uri(target_nodes, state)
        -- TODO: We probably should only do this if delete was successful?
        M.unmark_node(state, nil, true)
        if redraw then
            neo_tree_renderer.redraw(state)
        end
        if callback then callback() end
    end
end

function M.navigate(state, target_node)
    local tree = state.tree
    local render_tree = nil
    local render_parent = nil
    local do_redraw_only = false
    if not tree or not neo_tree_renderer.window_exists(state) then
        render_tree = M.internal.generate_tree(state)
    else
        target_node = target_node or tree and tree:get_node()
        if not target_node then
            render_tree = M.internal.generate_tree(state)
        elseif target_node then
            local mapped_node = get_mapped_node(target_node)
            if not mapped_node then
                logger.warnf("Unable to find matching mapped node for %s!", target_node:get_id())
                return
            end
            render_tree, do_redraw_only = mapped_node.navigate(target_node, state)
        if render_tree then
                render_parent = target_node:get_id()
            end
        end
    end
    M.internal.finish_navigate(state, render_tree, render_parent, do_redraw_only)
end

function M.rename(state)
    local tree = state.tree
    if not tree then
        logger.info("Unable to rename node as there is no tree to rename under. How did you do this????")
        return
    end
    local node = tree:get_node()
    local parent = tree:get_node(node:get_parent_id())
    -- Eventually we want this to be something that can be provided
    -- by the provider
    local path_sep = '/'
    local prompt = "Enter new name for this node"
    local hint = tree:get_node().name
    local process_rename = function(response)
        local uri = node:get_id()
        local old_name = node.name
        local new_path = string.format("%s%s%s", parent:get_id(), path_sep, response)
        local result = netman_api.rename(uri, new_path)
        if result.success then
            local notify_user_after_refresh = function()
                logger.infon(string.format("Renamed %s to %s", old_name, response))
            end
            local refresh_after_delete = function()
                refresh_uri({parent}, state, notify_user_after_refresh, new_path)
            end
            delete_uri({node}, state, refresh_after_delete, true)
        else
            logger.warn("Received unhandled error while renaming", result)
        end
    end
    neo_tree_input.input(prompt, hint, process_rename)
end

function M.unmark_node(state, node, dont_redraw)
    assert(state, "No state provided to unmark nodes in!")
    if not node then
        node = {}
    end
    if type(node) == 'string' then
        node = { node }
    end
    if node.get_id then
        -- the provided node is a nui node
        node = { node:get_id() }
    end
    local tree = state.tree
    if not tree then
        logger.warn("No tree associated with the state!")
        return
    end
    local nodes = {}
    if #node == 0 then
        for marked_node_id, _ in pairs(M.internal.marked_nodes) do
            table.insert(nodes, marked_node_id)
        end
    end
    for _, marked_node_id in ipairs(nodes) do
        logger.trace2f("Unmarked node %s", marked_node_id)
        local marked_node = tree:get_node(marked_node_id)
        if marked_node and marked_node.extra then
            marked_node.extra.marked = nil
        end
        M.internal.marked_nodes[marked_node_id] = nil
    end
    if not dont_redraw then
        neo_tree_renderer.redraw(state)
    end
end

function M.set_mark_action(action)
    -- TODO: This should be a global constant
    if not next(M.internal.marked_nodes) then
        logger.infon('There are no marked nodes, Please mark a node with the "x" button first')
        return
    end
    local is_valid_action = false
    for _, valid_action in ipairs(M.constants.ACTIONS) do
        if action == valid_action then
            is_valid_action = true
            break
        end
    end
    if not is_valid_action then
        logger.warnnf("Invalid action selection: %s", action)
        return
    end
    logger.warnnf('Setting action "%s" to run on marked nodes. To run the action, press "p"', action)
    M.internal.mark_action = action
end

function M.mark_node(state)
    local node, tree
    tree = state.tree
    if not tree then
        logger.warn("No tree found on neo-tree state. Unable to mark any nodes!")
        return
    end
    node = tree:get_node()
    if not node.extra or not node.extra.markable then
        logger.warnf("Node: %s is not markable", node:get_id())
        return
    end
    if node.extra.marked then
        M.internal.marked_nodes[node:get_id()] = nil
        node.extra.marked = nil
    else
        M.internal.marked_nodes[node:get_id()] = 1
        node.extra.marked = true
    end
    neo_tree_renderer.redraw(state)
end

function M.paste_node(state)
    -- TODO: We need to use a CONSTANT string for mark_action
    local tree
    assert(state, "No state provided to handle nodes in!")
    tree = state.tree
    if not tree then
        logger.warn("No tree found on neo-tree state. Unable to paste any nodes!")
        return
    end
    if not M.internal.mark_action then
        logger.info("No mark action set, defaulting to copy")
        M.internal.mark_action = M.constants.ACTIONS[1]
    end
    local orig_target = tree:get_node()
    local target_node = orig_target
    -- -- Ensure that the target is a directory
    while target_node.type ~= 'directory' do
        local parent_id = target_node:get_parent_id()
        if not parent_id then
            -- How tf did you accomplish this?
            logger.error("Somehow we are trying to paste to a node that has no parent?")
            logger.warnn("Invalid target |%s| for paste operation", orig_target:get_id())
            return
        end
        target_node = tree:get_node(target_node:get_parent_id())
    end
    local target_uri = target_node:get_id()
    local refresh_nodes = { target_uri }
    local uris = {}
    for marked_node_id, _ in pairs(M.internal.marked_nodes) do
        local node = tree:get_node(marked_node_id)
        if not node then goto continue end
        table.insert(uris, marked_node_id)
        local node_parent = node:get_parent_id()
        local already_have_parent = false
        for _, parent in ipairs(refresh_nodes) do
            if parent == node_parent then
                already_have_parent = true
                break
            end
        end
        if not already_have_parent then
            table.insert(refresh_nodes, node_parent)
        end
        ::continue::
    end
    local callback = function(data, complete)
        if data and data.message then
            logger.warnn(data.message)
            -- TODO: implement retry logic
            return
        end
        M.unmark_node(state, nil, true)
        local _refresh_nodes = {}
        for _, uri in ipairs(refresh_nodes) do
            _refresh_nodes[uri] = 1
        end
        M.internal.internally_marked_nodes = _refresh_nodes
        M.refresh(state)
        -- Refresh the parent of each uri as well as the target_uri
    end
    if M.internal.mark_action == M.constants.ACTIONS[1] then
        -- Do a copy action
        local handle = netman_api.copy(uris, target_uri, {}, callback)
        -- TODO: Save the handle somewhere?
    elseif M.internal.mark_action == M.constants.ACTIONS[2] then
        local handle = netman_api.move(uris, target_uri, {}, callback)
    end
end

function M.setup()
    logger.debug("Initializing Neotree Node Type Navigation Map")
    M.internal.navigate_map[M.constants.ROOT_IDS.NETMAN_PROVIDERS] = navigate_root_provider
    M.internal.navigate_map[M.constants.ROOT_IDS.NETMAN_FAVORITES] = navigate_directory
    M.internal.navigate_map[M.constants.ROOT_IDS.NETMAN_RECENTS] = navigate_directory
    M.internal.navigate_map[M.constants.TYPES.NETMAN_FILE] = navigate_uri
    M.internal.navigate_map[M.constants.TYPES.NETMAN_EXPLORE] = navigate_uri
    M.internal.navigate_map[M.constants.TYPES.NETMAN_HOST] = navigate_uri
    M.internal.navigate_map[M.constants.TYPES.NETMAN_PROVIDER] = navigate_provider
    logger.debug("Initializing Neotree Node Type Refresh Map")
    M.internal.refresh_map[M.constants.TYPES.NETMAN_PROVIDER] = refresh_provider
    for _, node in pairs(M.internal._root_nodes) do
        logger.trace2("Creating nui node for root node", node)
        create_node(node)
        table.insert(M._root, node.id)
    end
end
return M
