local netman_utils = require("netman.tools.utils")
local netman_api = require("netman.api")
local netman_types = require("netman.tools.options").api.READ_TYPE
local netman_type_attributes = require("netman.tools.options").api.ATTRIBUTES
local neo_tree_utils = require("neo-tree.utils")
local neo_tree_renderer = require("neo-tree.ui.renderer")
local netman_ui = require("netman.ui")
local logger = netman_ui.get_logger()
local neo_tree_defaults = require("netman.ui.neo-tree.defaults")

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
        NETMAN_RECENTS   = "netman_recents",
        NETMAN_FAVORITES = "netman_favorites",
        NETMAN_PROVIDERS = "netman_providers",
    }
}

M.name = "remote"
M.display_name = 'ﯱ Remote'
M.default_config = neo_tree_defaults

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
    {
        name = "Recents",
        id = M.constants.ROOT_IDS.NETMAN_RECENTS,
        type = M.constants.TYPES.NETMAN_BOOKMARK,
        children = {},
        parent_id = nil,
        extra = {
            icon = "",
        }
    },
    {
        id = M.constants.ROOT_IDS.NETMAN_FAVORITES,
        name = "Favorites",
        type = M.constants.TYPES.NETMAN_BOOKMARK,
        children = {},
        parent_id = nil,
        extra = {
            icon = "",
        }
    },
    {
        name = "Providers",
        id = M.constants.ROOT_IDS.NETMAN_PROVIDERS,
        type = M.constants.TYPES.NETMAN_BOOKMARK,
        children = {},
        parent_id = nil,
        extra = {
            icon = "",
            skip = false,
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
        collapsed = node_details.collapsed, -- We may not need this variable now
    }
    local nui_node = {
        id = node.id,
        name = node.name,
        type = node.type,
        extra = node_details.extra or {}
    }
    if not node.id then
        logger.warn("Node was created with no id!", node_details)
    end
    if not node.name then
        logger.warn("Node was created with no name!", node_details)
    end
    if not node.type then
        logger.warn("Node was created with no type!", node_details)
    end
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
    -- TODO: I hate that this is recursive...
    local tree = {}
    for _, leaf_id in ipairs(in_tree) do
        local leaf = M.internal.node_map[leaf_id]
        if not leaf.extra.skip then
            local node = leaf.extra.nui_node
            if leaf.children then
                node.children = tree_to_nui(leaf.children, do_sort)
            end
            table.insert(tree, node)
        end
    end
    if do_sort then
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
        node.collapsed = true
    else
        nui_node:expand()
        node.collapsed = false
        if #node.children > 0 then
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
        logger.debug("Adding provider table to root providers node", providers)
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
        node.collapsed = true
    else
        nui_node:expand()
        -- Get content for the node
        node.collapsed = false
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
        node.collapsed = true
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
        node.collapsed = false
        return tree_to_nui(hosts, true)
    end
    return nil, true
end

local function refresh_provider(nui_node)
    local node = M.internal.node_map[nui_node.id]
    logger.infof("Refreshing Node: %s", node.name)
end
----------------- /\ Provider Helper Functions

----------------- \/ URI Helper Functions
local function open_file(file)

end

local function open_directory(directory, parent_id)
    local parent_node = M.internal.node_map[parent_id]
    for _, raw_node in ipairs(directory.data) do
        local node = {
            id = raw_node.URI,
            name = raw_node.NAME,
            type = M.constants.ATTRIBUTE_MAP[raw_node.FIELD_TYPE],
            children = {},
            extra = {
                uri = raw_node.URI,
                metadata = raw_node.METADATA
            }
        }
        create_node(node, parent_id)
    end
    local children = parent_node.children
    return tree_to_nui(children, true)
end

local function open_stream(stream)

end

local function async_process_uri_results(results, parent_id)
    -- TODO: Handle failure somehow?
    local results_type = results.type
    if results_type == netman_types.EXPLORE then
        return open_directory(results, parent_id)
    elseif results_type == netman_types.FILE then
        return open_file(results)
    else
        return open_stream(results)
    end
end

local function navigate_uri(nui_node, state)
    -- TODO: We need something to prevent accidentally executing "multiple" reads at once
    local node = get_mapped_node(nui_node)
    if nui_node:is_expanded() then
        -- Collapse the node and return
        nui_node:collapse()
        node.collapsed = true
        return nil, true
    end
    -- We should temporarily map something globally to cancel the read?
    -- Or add something to the top of the tree to "stop" the handle?

    M.internal.current_process_handle = netman_api.read(node.extra.uri, {}, function(data, complete)
        local render_tree = async_process_uri_results(data, node.id)
        if complete then
            M.internal.finish_navigate(state, render_tree, nui_node:get_id())
        end
    end)
    -- Returing "true" so we can update to show the "refresh"/"loading" icon
    return nil, true
end

local function refresh_uri(nui_node)

end
----------------- /\ URI Helper Functions

function M.internal.generate_tree(state)
    return tree_to_nui(M._root)
end

function M.internal.finish_navigate(state, render_tree, render_parent, do_redraw_only)
    if do_redraw_only then
        neo_tree_renderer.redraw(state)
    elseif render_tree and #render_tree > 0 then
        -- Purge children?
        neo_tree_renderer.show_nodes(render_tree, state, render_parent)
    end
end

function M.navigate(state)
    local tree = state.tree
    local render_tree = nil
    local render_parent = nil
    local do_redraw_only = false
    -- We should see if we can just redraw the tree?
    if not tree or not neo_tree_renderer.window_exists(state) then
        render_tree = M.internal.generate_tree(state)
    else
        local target_node = tree and tree:get_node()
        if not target_node then
            -- There is nothing to do, render the root tree and move on
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
        create_node(node)
        table.insert(M._root, node.id)
    end
    logger.debug("Root", M._root)
end

return M
