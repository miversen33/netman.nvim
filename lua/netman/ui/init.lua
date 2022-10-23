local M = {}

--- Returns a 1 dimensional table of strings (providers)
--- Really just calling netman.api.get_providers
--- @return table
function M.get_providers()
    local _providers = require("netman.api").internal.get_providers()
    local providers = {}
    for _, provider in ipairs(_providers) do
        if require(provider).get_hosts ~= nil then
            table.insert(providers, provider)
        else
            require("netman.tools.utils").log.info(string.format("Provider %s does not implemented the `get_hosts` function that is required to be displayed in a UI", provider))
        end
    end
    return providers
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
    local schema = require("netman.tools.options").ui.ENTRY_SCHEMA
    for _, _entry in pairs(entries) do
        local entry = {}
        for key, value in pairs(_entry) do
            if schema[key] then
                entry[key] = value
            else
                require("netman.tools.utils").log.warn(string.format("%s provided invalid key: %s", provider, key))
            end
        end
        table.insert(_data, entry)
    end
    return _data
end

return M
