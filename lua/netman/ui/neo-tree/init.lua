--This file should have all functions that are in the public api and either set
--or read the state of this source.

local renderer = require("neo-tree.ui.renderer")
local events = require("neo-tree.events")
local neo_tree_utils = require("neo-tree.utils")

local M = {
    name = "remote",
    internal = {
        providers = {},
        node_id_map = {},
        last_id = 0
    },
}

M.internal.sorter = function(a, b) return a.name < b.name end

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
            icon     = _provider.icon,
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
    -- Ok so this is a little bit ugly but lets explain what we are doing
    local internal_node = M.internal.get_internal_node(node:get_id())

    -- If the item being selected in neo-tree is a "file", we treat it as such.
    -- However, the "file" doesn't exist in the filesystem so we need to do some 
    -- shenanigans with Netman to pull it down.
    -- The way we do that is, make Neotree give us a buffer with the appropriate name
    -- of the URI we are pulling down, and then let netman stuff the content into the newly
    -- created buffer.
    -- LET NEOTREE HANDLE BUFFER MANAGEMENT
    if internal_node.type == 'file' then
        local _event_handler_id = "netman_dummy_file_event"
        local _dummy_file_open_handler = {
            event = "file_opened",
            id=_event_handler_id
        }
        _dummy_file_open_handler.handler = function()
            events.unsubscribe(_dummy_file_open_handler)
            require("netman").read(internal_node.uri)
        end
        events.subscribe(_dummy_file_open_handler)
        neo_tree_utils.open_file(state, internal_node.uri)
        return
    end

    local _host_contents = require("netman.api").read(internal_node.uri)
    if not _host_contents or not _host_contents.contents then
        require("netman.tools.utils").log.warn(string.format("Unable to process %s!", internal_node.uri))
        return
    end

    local contents          = _host_contents.contents
    local entries           = {}
    local name_to_entry_map = {}
    local _unsorted_entries = {}
    local _sorted_entries   = {}

    for _, item in ipairs(contents) do
        local entry = {
            id = string.format("%s", M.internal.last_id + 1),
            name = item.NAME,
            uri = item.URI
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
M.navigate = function(state)
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

end

return M
