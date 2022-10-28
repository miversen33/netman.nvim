--This file should have all functions that are in the public api and either set
--or read the state of this source.

local renderer = require("neo-tree.ui.renderer")
local events = require("neo-tree.events")
local neo_tree_utils = require("neo-tree.utils")
local defaults = require("netman.ui.neo-tree.defaults")

local M = {
    name = "remote",
    internal = {
        providers = {},
        node_id_map = {},
        last_id = 0
    },
}

--- Will add the host to the "recents" node
M.add_recent_host = function(provider, host)
    local config = M.internal.get_netman_config()
    local provider_recents = config:get('recents')[provider]
    if not provider_recents then
        provider_recents = {}
        config:get('recents')[provider] = provider_recents
    end
    provider_recents[host] = vim.loop.now()
    config:save()
end

--- Will remove the host from the "recents" node
M.remove_recent_host = function(provider, host)
    local config = M.internal.get_netman_config()
    local provider_recents = config:get('recents')[provider]
    config:get('recents')[provider] = nil
    config:save()
end

-- TODO: Finish setting up all of the favorite/recent stuff
--- Will either favorite the host or remove favorite on host
M.favorite_toggle = function(provider, host)
    local config = M.internal.get_netman_config()
    local provider_favorites = config:get('favorites')[provider]
    if not provider_favorites then
        provider_favorites = {[host] = 1}
        config:get('favorites')[provider] = provider_favorites
    else
        provider_favorites[host] = nil
    end
    config:save()
end

--- Will either mark the host as hidden or remove the hidden attribute
M.hide_toggle = function(provider, host)
    local config = M.internal.get_netman_config()
    local provider_hidden_hosts = config:get('hidden')[provider]
    if not provider_hidden_hosts then
        config:get('hidden')[provider] = {[host]=1}
    else
        provider_hidden_hosts[host] = nil
    end
    config:save()
end

M.internal.sorter = function(a, b) return a.name < b.name end

--- Reaches out to the generic Netman UI tool to fetch our config
--- @return Configuration
M.internal.get_netman_config = function() return
    require("netman.ui").get_config("netman.ui.neo-tree")
end

--- Invalidates the internally cached provider tree. This will be called
--- anytime a provider is unloaded or loaded into netman
M.internal.invalidate_provider_cache = function()
    M.internal.generate_root_tree()
end

--- I mean, does whats on the tin guy
M.internal.increment_last_id = function()
    M.internal.last_id = M.internal.last_id + 1
end

--- Fetches the internal (to this class) node for the provided neo-tree id
--- @param id string
--- @return table
---     Who knows what this table will have on it! Enjoy!
M.internal.get_internal_node = function(id)
    return M.internal.node_id_map[id]
end

--- Saves the internal (to this class) node, mapping it to the provided neo-tree id
M.internal.set_internal_node = function(id, node)
    M.internal.node_id_map[id] = node
end

--- Generates the base provider tree that Neo-tree should display
M.internal.generate_root_tree = function()
    local providers = require("netman.ui").get_providers()

    local entries = {}
    -- Make sure this is in alphabetical order
    for _, provider in ipairs(providers) do
        local _status, _provider = pcall(require, provider)
        if not  _status then
            require("netman.tools.utils").log.warn(string.format("Unable to add %s to Neo-tree. Received Error", provider), {error=_provider})
            goto continue
        end
        local name = _provider.name
        local entry = {
            id       = string.format('%s', M.internal.last_id + 1),
            name     = name,
            type     = "netman_provider",
            provider = provider,
            icon     = _provider.ui.icon,
            hl       = _provider.icon_highlight
        }
        M.internal.set_internal_node(entry.id, entry)
        table.insert(entries, entry)
        M.internal.increment_last_id()
        ::continue::
    end
    table.sort(entries, M.internal.sorter)
    M.internal.providers = entries
end

M.internal.navigate_to_root = function(state)
    M.internal.generate_root_tree()
    local entries = M.internal.providers
    renderer.show_nodes(entries, state)
end

M.internal.navigate_to_provider = function(state, node, provider)
    local _entries = require("netman.ui").get_entries_for_provider(provider)

    local entries = {}
    for _, _entry in ipairs(_entries) do
        local entry = {
            id = string.format('%s', M.internal.last_id + 1),
            name = _entry.NAME,
            type = 'netman_host',
            provider = provider,
            host = _entry.NAME,
            uri = _entry.URI,
            state = _entry.STATE,
            last_accessed = _entry.LAST_ACCESSED
        }
        M.internal.set_internal_node(entry.id, entry)
        M.internal.increment_last_id()
        table.insert(entries, entry)
    end
    table.sort(entries, M.internal.sorter)
    renderer.show_nodes(entries, state, node:get_id())
end


M.internal.navigate_host = function(state, node)
    -- This should eventually be set by whatever form of open command was done in neo-tree
    local open_command = 'read ++edit '
    local command = ''
    -- local command = ' | set nomodified | filetype detect'
    local internal_node = M.internal.get_internal_node(node:get_id())
    if not internal_node then
        require("netman.tools.utils").log.warn("No internal node found for %s", node:get_name())
        return
    end

    local host_data = require("netman.api").read(internal_node.uri)
    require("netman.tools.utils").log.trace({host_data=host_data})
    if not host_data then
        require("netman.tools.utils").log.warn(string.format("Uri: %s did not return anything to display!", internal_node.uri))
        return
    end
    if host_data.type == 'FILE' or host_data.type == 'STREAM' then
        -- Handle content to display in a buffer
        if host_data.type == 'STREAM' then
            command = '0append! ' .. table.concat(host_data.data) .. command
        else
            command = open_command .. host_data.data.local_path .. command
        end
        require("netman.tools.utils").log.debug({command=command})
        local _event_handler_id = "netman_dummy_file_event"
        local _dummy_file_open_handler = {
            event = "file_opened",
            id=_event_handler_id
        }
        _dummy_file_open_handler.handler = function()
            events.unsubscribe(_dummy_file_open_handler)
            require("netman.tools.utils").render_command_and_clean_buffer(command)
        end
        events.subscribe(_dummy_file_open_handler)
        neo_tree_utils.open_file(state, internal_node.uri)
        return
    end

    local data              = host_data.data
    local entries           = {}
    local name_to_entry_map = {}
    local _unsorted_entries = {}
    local _sorted_entries   = {}

    for _, item in ipairs(data) do
        local entry = {
            id = string.format("%s", M.internal.last_id + 1),
            name = item.NAME,
            uri = item.URI,
            host = internal_node.host
        }
        if item.FIELD_TYPE == 'LINK' then
            entry.type = 'directory'
        else
            entry.type = 'file'
        end
        M.internal.increment_last_id()
        M.internal.set_internal_node(entry.id, entry)
        name_to_entry_map[entry.name] = entry
        table.insert(_unsorted_entries, entry.name)
    end
    _sorted_entries = neo_tree_utils.sort_by_tree_display(_unsorted_entries)
    for _, entry in ipairs(_sorted_entries) do
        table.insert(entries, name_to_entry_map[entry])
    end
    renderer.show_nodes(entries, state, node:get_id())
end

--- Navigate to the given path.
--- @param state table
---     I'll be honest, I have absolutely no idea what state is, its
---     an object that comes from neo-tree. Any usage of it in this file
---     is due to reflection shenanigans to figure out what is in it
--- @param window_state string
---     If provided, this is the state the open window needs to be in
---     when a new file is opened.
---     Default: nil
---     Valid Options:
---         - split
---         - vsplit
---         - tab
---         - tab drop
---         - drop
--- @return nil
M.navigate = function(state, window_state)
    local tree, neo_tree_node, internal_node
    tree = state.tree

    -- There is nothing currently displayed, generate the basic
    -- Provider Tree
    if tree == nil then
        M.internal.navigate_to_root(state)
        return
    end
    neo_tree_node = tree:get_node()
    -- WARN: This might not be the best place for this?
    if neo_tree_node:is_expanded() then
        neo_tree_node:collapse()
        renderer.redraw(state)
        return
    end

    internal_node = M.internal.node_id_map[neo_tree_node:get_id()]
    if internal_node.host and internal_node.provider then
        -- Adding the host to the recents node
        M.add_recent_host(internal_node.provider, internal_node.host)
    end

    -- Display the available hosts for the selected provider
    if internal_node.type == 'netman_provider' then
        M.internal.navigate_to_provider(state, neo_tree_node, internal_node.provider)
        return
    -- Display whatever the provider thinks we should display for the selected host
    else
        M.internal.navigate_host(state, neo_tree_node)
        return
    end
end

---Configures the plugin, should be called before the plugin is used.
---@param config table Configuration table containing any keys that the user
--wants to change from the defaults. May be empty to accept default values.
M.setup = function(config, global_config)
    local netman_config = M.internal.get_netman_config()
    require("netman.tools.utils").log.debug(netman_config)
    -- This seems to be resetting these on load?
    if not netman_config:get('recents') then
        require("netman.tools.utils").log.info("Creating Recents Table in Netman Neotree Configuration")
        netman_config:set('recents', {})
    end
    if not netman_config:get('favorites') then
         require("netman.tools.utils").log.info("Creating Favorites Table in Netman Neotree Configuration")
         netman_config:set('favorites', {})
    end
    if not netman_config:get('hidden') then
        require("netman.tools.utils").log.info("Creating Hidden Table in Netman Neotree Configuration")
        netman_config:set('hidden', {})
    end
    netman_config:save()
end

M.default_config = defaults

return M
