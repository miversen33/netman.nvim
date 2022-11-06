--- Basic, Generic, Caching class to be used for storing items
--- that need to be expired after `n` time
local clock = vim.loop.hrtime

local Cache = {}
Cache._cache = {}
Cache.SECOND =  1000000000
Cache.MINUTE = Cache.SECOND * 60
Cache.HOUR = Cache.MINUTE * 60
Cache.DAY = Cache.HOUR * 24
Cache.FOREVER = -1

function Cache:_validate_entry(key)
    local item = self._cache[key]
    if not item then return nil end
    if item.expiration > 0 and item.expiration < clock() then
        self._cache[key] = nil
        return nil
    end
end

--- Performs a validation sweep across the top layer of the cache to ensure the cache
--- is in a valid state
function Cache:validate()
    for key, _ in pairs(self._cache) do
        self:_validate_entry(key)
    end
end

--- Clears out the internal cache store
function Cache:invalidate()
    self._cache = {} -- There may be a more performant way of clearing this
end

--- Adds item to the internal cache store
--- @param key any
---     The key to use for accessing the cached item later
--- @param item any
---     The item to store in cache
--- @param ttl integer
---     Default: nil
---     An integer (in nanoseconds) for how long this item should live
---     If below 0 or nil, assumes no TTL (IE, item lives forever)
---     Helper attributes are associated with Cache
---     Cache.SECOND, Cache.MINUTE, Cache.HOUR, Cache.DAY, Cache.FOREVER
function Cache:add_item(key, item, ttl)
    ttl = ttl or self.__default_ttl
    local expiration = nil
    if ttl == Cache.FOREVER then
        expiration = ttl
    else
        expiration = clock() + ttl
    end
    self._cache[key] = {item=item, expiration=expiration}
end

--- Returns an item from internal cache store. Note, checks item ttl before return
--- @param key any
---     The key for the value associated
--- @return any
---     The item associated or nil if the item does not exist.
function Cache:get_item(key)
    self:_validate_entry(key)
    local item = self._cache[key]
    if item then return item.item else return nil end
end

--- Removes item from internal cache store.
--- @param key any
---     The key to remove for the associated value
function Cache:remove_item(key)
    self._cache[key] = nil
end

--- Returns the cache in a frozen state as a table
--- Note: This table is _not_ updated, it is a frozen copy of the cache at the time of call
--- @return table
---     The contents of the cache
function Cache:as_table()
    self:validate()
    local _table = {}
    for key, value in pairs(self._cache) do
        if value.__type and value.__type == 'netman_cache' and value.as_table then
            value = value:as_table()
        end
        _table[key] = value.item
    end
    return _table
end

--- Returns the number of keys in the cache
--- @return int
function Cache:len()
    self:validate()
    -- Pretty ick but there may not be a better way to do this?
    local size = 0
    for _, _ in pairs(self._cache) do
        size = size + 1
    end
    return size
end

--- Clears out the cache
function Cache:clear()
    self._cache = {}
end

--- Creates a new cache object with the default ttl being set to
--- "default"
--- @param default_ttl integer
---     Default: Cache.FOREVER
---     Integer indicating the default ttl to use on add_item
function Cache:new(default_ttl)
    default_ttl = default_ttl or Cache.FOREVER
    local new_cache = {}
    setmetatable(new_cache, self)
    self.__index = self
    new_cache._cache = {}
    new_cache.__default_ttl = default_ttl
    new_cache.__type = 'netman_cache'
    return new_cache
end

return Cache
