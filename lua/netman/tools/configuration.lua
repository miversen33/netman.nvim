--- Serializable (json format for now) configuration object
--- that Netman will provide to each registered provider.
--- WARN: Providers configurations are stored based on their
--- module path. If your module path changes, you will receive
--- a new configuration (and the old will likely be lost).
local Configuration = {}

--- Creates a new configuration object. You shouldn't be here
--- unless you are looking at how a provider gets its configuration
function Configuration:new(starter_data)
    local new_configuration = {}
    setmetatable(new_configuration, self)
    self.__index = self
    new_configuration.__type = "netman_config"
    new_configuration.__data = {}
    if starter_data then
        for key, value in pairs(starter_data) do
            new_configuration:set(key, value)
        end
    end
    return new_configuration

end

--- Returns whatever is associated with the "key", including nil
function Configuration:get(key)
    return self.__data[key]
end

--- Sets the value as an association with the key
--- WARN: Ensure that whatever you are saving as "value" is
--- Serializable or neovim will explode and the world will shame you
function Configuration:set(key, value)
    self.__data[key] = value
end

--- Removes the provided key from the configuration
function Configuration:del(key)
    self.__data[key] = nil
end

--- Stubbing out the configuration save method.
--- Check out netman.api.init_config for details on how save works.
--- Note: If you are using the configuration provided to your provider,
--- this will _not_ error as Netman's API sets a save function on each
--- configuration
function Configuration:save()
    error("Not Implemented!")
end

--- Returns the configuration as a string
function Configuration:serialize()
    return vim.fn.json_encode(self:_as_table())
end

--- Returns the data within the configuration in a table
function Configuration:_as_table()
    local _table = {}
    for key, value in pairs(self.__data) do
        if type(value) == 'table' and value.__type == 'netman_config' then
            _table[key] = value:_as_table()
        else
            _table[key] = value
        end
    end
    return _table
end

return Configuration
