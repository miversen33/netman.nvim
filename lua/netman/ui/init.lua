local M = {
    internal = {},
}

--- Returns a 1 dimensional table of strings (providers)
--- Really just calling netman.api.get_providers
--- @return table
function M.get_providers()
    local _providers = require("netman.api").internal.get_providers()
    local providers = {}
    for _, provider in ipairs(_providers) do
        if require(provider).ui ~= nil then
            table.insert(providers, provider)
        else
            require("netman.tools.utils").log.info(string.format("Provider %s does not implemented the `get_hosts` function that is required to be displayed in a UI", provider))
        end
    end
    return providers
end

--- Validates the information provided by the entry to ensure it 
--- matches the defined schema in netman.tools.options.ui.ENTRY_SCHEMA.
--- If there are any invalid keys, they will be logged and stripped out.
--- @param entry table
---     A single entry returned by netman.api.get_hosts
--- @return table
---     A validated/sanitized entry
---     NOTE: If the entry is not validated, this returns nil
function M.internal.validate_entry_schema(provider, entry)
    local schema = require("netman.tools.options").ui.ENTRY_SCHEMA
    local states = require("netman.tools.options").ui.STATES
    local host = nil
    local invalid_state = nil
    local valid_entry = true
    local return_entry = {}
    for key, value in pairs(entry) do
        if not schema[key] then
            require("netman.tools.utils").log.warn(string.format("%s provided invalid key: %s", provider, key))
            valid_entry = false
            goto continue
        end
        if key == 'STATE' and value and not states[value] then
            invalid_state = value
            valid_entry = false
            goto continue
        end
        if key == 'NAME' then host = value end
        return_entry[key] = value
        ::continue::
    end
    if invalid_state then
        require("netman.tools.utils").log.warn(string.format("%s provided invalid state: %s for host: %s", provider, invalid_state, host))
        valid_entry = false
    end
    if not valid_entry then return nil else return return_entry end
end

--- Reaches out to the provider and retrieves a table that contains entries which
--- matches the netman.options.ui.ENTRY_SCHEMA spec
--- NOTE: If an entry has invalid keys, those keys are stripped out, but the entry
--- is still returned
--- @param provider string
---     The string name of the provider in question. If the provider is invalid or
---     not UI ready, we will just return nil
--- @return table/nil
---    Returns a 1 dimensional table with entries ready to be parsed for UI processing
function M.get_entries_for_provider(provider)
    local entries = require("netman.api").internal.get_provider_entries(provider)
    -- Short circuit that says the provider is not valid
    if not entries then return nil end
    if not type(entries) == 'table' then
        require("netman.tools.utils").log.error(string.format("%s provided an invalid type of data"))
        return nil
    end
    local _data = {}
    for _, entry in pairs(entries) do
        local _entry = M.internal.validate_entry_schema(provider, entry)
        if _entry then table.insert(_data, _entry) end
    end
    return _data
end

--- Returns a configuration specifically for whatever UI consumer is requesting it.
--- If the consumer doesn't have a configuration, we will create it for them on request
--- @param consumer string
---     The path to the consumer. For example, netman.ui.neo-tree
--- @return Configuration
function M.get_config(consumer)
    local ui_config = require("netman.api").internal.get_config('netman.ui')
    local consumer_config = ui_config:get(consumer)
    if not consumer_config then
        require("netman.tools.utils").log.info(string.format("Creating new UI configuration for %s", consumer))
        consumer_config = require("netman.tools.configuration"):new()
        consumer_config.save = ui_config.save
        ui_config:set(consumer, consumer_config)
        ui_config:save()
    elseif not consumer_config.__type or consumer_config.__type ~= 'netman_config' then
        -- We got _something_ but its not a netman configuration. Most likely this
        -- was a config but was serialized out and newly loaded in from a json
        consumer_config = require("netman.tools.configuration"):new(consumer_config)
        consumer_config.save = ui_config.save
    end
    return consumer_config
end

return M
