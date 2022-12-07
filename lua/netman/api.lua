-- TODO: (Mike): MOAR LOGS
local notify = require("netman.tools.utils").notify
local log = require("netman.tools.utils").log
local netman_options = require("netman.tools.options")
local cache_generator = require("netman.tools.cache")

local M = {}

--- WARN: Do not rely on these functions existing
--- WARN: Do not use these functions in your code
--- WARN: If you put an issue in saying anything about using
--- these functions is not working in your plugin, you will
--- be laughed at and ridiculed
M.internal = {
    config = require("netman.tools.configuration"):new(),
    -- This will be used to help track unused configurations
    boot_timestamp = vim.loop.now()
}

--- Set of tools to communicate directly with provider(s) (in a generic sense).
--- Note, this will not let you talk directly to the provider per say, (meaning you can't
--- talk straight to the ssh provider, but you can talk to api and tell it you want things
--- from or to give to the ssh provider).
M.providers = {}

--- The default function that any provider configuration will have associated with its
--- :save function.
M.internal.config.save = function(self)
    local _config = io.open(require("netman.tools.utils").netman_config_path, 'w+')
    if not _config then
        error(string.format("Unable to write to netman configuration: %s",
            require("netman.tools.utils").netman_config_path))
        return
    end
    local _data = self:serialize()
    _config:write(_data)
    _config:flush()
    _config:close()
end

-- Gets set to true after init is complete
M._inited = false
M._providers = {
    protocol_to_path = {},
    path_to_provider = {},
    uninitialized    = {},
    file_cache       = {}
}

M._explorers = {}

local protocol_pattern_sanitizer_glob = '[%%^]?([%w-.]+)[:/]?'
local protocol_from_path_glob = '^([%w%-.]+)://'
local package_path_sanitizer_glob = '([%.%(%)%%%+%-%*%?%[%^%$]+)'
-- TODO(Mike): Potentially implement auto deprecation/enforcement here?
local _provider_required_attributes = {
    'name'
    , 'protocol_patterns'
    , 'version'
    , 'read'
    , 'write'
    , 'delete'
    , 'get_metadata'
}

--- WARN: Do not rely on these functions existing
--- WARN: Do not use these functions in your code
--- WARN: If you put an issue in saying anything about using
--- these functions is not working in your plugin, you will
--- be laughed at and ridiculed
function M.internal.init_config()
    local _lines = {}
    local _config = io.open(require("netman.tools.utils").netman_config_path, 'r')
    assert(_config,
        string.format("Unable to read netman configuration file: %s", require("netman.tools.utils").netman_config_path))
    for line in _config:lines() do table.insert(_lines, line) end
    _config:close()
    if next(_lines) then
        log.trace("Decoding Netman Configuration")
        local success = false
        success, _config = pcall(vim.fn.json_decode, _lines)
        if not success then
            _config = {}
        end
    else
        _config = {}
    end
    ---@diagnostic disable-next-line: need-check-nil
    if not _config['netman.ui'] then _config['netman.ui'] = {} end
    for key, value in pairs(_config) do
        local new_config = require("netman.tools.configuration"):new(value)
        new_config.save = function(_) M.internal.config:save() end
        M.internal.config:set(key, new_config)
    end
    if not M.internal.config:get('netman.core') then
        local new_config = require("netman.tools.configuration"):new()
        new_config.save = function(_) M.internal.config:save() end
        new_config:set('_last_loaded', vim.loop.now())
        M.internal.config:set('netman.core', new_config)
        M.internal.config:save()
    end

    log.trace("Loaded Configuration")
end

--- WARN: Do not rely on these functions existing
--- WARN: Do not use these functions in your code
--- WARN: If you put an issue in saying anything about using
--- these functions is not working in your plugin, you will
--- be laughed at and ridiculed
--- Retrieves the provider and its cache for a protocol
--- @param protocol string
---     The protocol to check against
--- @return any, netman.tools.cache
---     Will return nil if we are unable to find a matching provider
function M.internal.get_provider_for_protocol(protocol)
    local provider_path = M._providers.protocol_to_path[protocol]
    if not provider_path then return nil end
    local provider_details = M._providers.path_to_provider[provider_path]
    return provider_details.provider, provider_details.cache
end

--- WARN: Do not rely on these functions existing
--- WARN: Do not use these functions in your code
--- WARN: If you put an issue in saying anything about using
--- these functions is not working in your plugin, you will
--- be laughed at and ridiculed
--- Retrieves the provider details for a URI
---@param uri string
--- The URI to extract the protocol (and thus the provider) from
---@return any, string/any, string/any
--- Returns the provider, its import path, and the protocol associated with the provider
---@private
function M.internal.get_provider_for_uri(uri)
    uri = uri or ''
    local protocol = uri:match(protocol_from_path_glob)
    local provider, cache = M.internal.get_provider_for_protocol(protocol)
    return provider, cache, protocol
end

--- WARN: Do not rely on these functions existing
--- WARN: Do not use these functions in your code
--- WARN: If you put an issue in saying anything about using
--- these functions is not working in your plugin, you will
--- be laughed at and ridiculed
function M.internal.validate_uri(uri)
    local provider, cache, protocol = M.internal.get_provider_for_uri(uri)
    if not provider then
        log.warn(string.format("%s is not ours to deal with", uri))
        return nil -- Nothing to do here, this isn't ours to handle
    end
    return uri, provider, cache, protocol
end

--- WARN: Do not rely on these functions existing
--- WARN: Do not use these functions in your code
--- WARN: If you put an issue in saying anything about using
--- these functions is not working in your plugin, you will
--- be laughed at and ridiculed
--- @param read_data table
---     A table which should contain the following keys
---         remote_files: 1 dimensional table
--- @return table
function M.internal.sanitize_explore_data(read_data)
    local sanitized_data = {}
    for _, data in pairs(read_data) do
        for key, value in ipairs(data) do
            if netman_options.explorer.FIELDS[key] == nil then
                log.warn("Removing " .. key .. " from directory data as it " ..
                    "does not conform with netman.options.explorer.FIELDS...")
                data[key] = nil
            elseif key == netman_options.explorer.FIELDS.METADATA then
                for _metadata_flag, _ in pairs(value) do
                    if netman_options.explorer.METADATA[_metadata_flag] == nil then
                        log.warn("Removing metadata flag " .. _metadata_flag .. " from items metadata as it " ..
                            "does not conform with netman.options.explorer.METADATA...")
                        value[_metadata_flag] = nil
                    end
                end
            end
        end
        local acceptable_output = true
        for _, field in ipairs(netman_options.explorer.FIELDS) do
            if data[field] == nil then
                log.warn("Explorer Data Missing Required Field: " .. field)
                acceptable_output = false
            end
        end
        if acceptable_output then
            table.insert(sanitized_data, data)
        end
    end
    return sanitized_data
end

--- Validates that the data provided in the `read` command for type `READ_FILE` is valid
--- @param table
---     Expects a table that contains the following keys
---     - remote_path  (Required)
---         - Value: String
---     - local_path   (Required)
---         - Value: String
---     - display_name (Optional)
---         - Value: String
---     - error        (Required if other fields are missing)
---         - TODO: Document this
---         - Value: Function
---         - Note: The expected return of the function is `{retry=bool}` where `bool` is either true/false. If `retry`
---         isn't present in the return of the error, or it if is and its false, we will assume that we shouldn't return
---         the read attempt
---     More details on the expected schema can be found in netman.tools.options.api.READ_RETURN_SCHEMA
--- @return table
---     Returns the validated table of information or (nil) if it cannot be validated
function M.internal.sanitize_file_data(read_data)
    log.trace("Validating Read File Data", read_data)
    local REQUIRED_KEYS = { 'local_path', 'origin_path' }
    if read_data.error then
        log.warn("Received error from read attempt. Returning error")
        return {
            error = read_data.error
        }
    end
    local valid = true
    local MISSING_KEYS = {}
    for _, key in ipairs(REQUIRED_KEYS) do
        if not read_data[key] then
            valid = false
            table.insert(MISSING_KEYS, key)
        end
    end
    if not valid then
        log.warn("Read Data was missing the following required keys", MISSING_KEYS)
        ---@diagnostic disable-next-line: return-type-mismatch
        return nil
    end
    return read_data
end

function M.internal.read_au_callback(callback_details)
    local uri = callback_details.match
    if M.internal.get_provider_for_uri(uri) then
        log.trace(string.format("Reading %s", uri))
        require("netman").read(uri)
        return
    end
    log.warn(string.format("Cannot find provider match for %s | Unable to read %s", uri, uri))
end

function M.internal.write_au_callback(callback_details)
    -- For some reason, providers aren't being found on write?
    log.debug({callback=callback_details})
    local uri = callback_details.match
    if M.internal.get_provider_for_uri(uri) then
        log.trace(string.format("Writing contents of buffer to %s", uri))
        require("netman").write(uri)
        return
    end
    log.warn(string.format("Cannot find provider match for %s | Unable to write to %s", uri, uri))
    return false
end

function M.internal.buf_focus_au_callback(callback_detail)
    -- For the time being, we probably dont care about when a buffer is focused.
    -- However in the future, it would be helpful if we can tell the UIs that one of their open
    -- files is in focus. Idk, it might make more sense to let them track that
end

function M.internal.buf_close_au_callback(callback_details)
    local uri = callback_details.match
    if M.internal.get_provider_for_uri(uri) then
        M.unload_buffer(uri)
    end
    log.info(string.format("Cannot find provider match for %s | It appears that the uri was abandoned?", uri))
end

function M.internal.init_provider_autocmds(provider, protocols)
    local aus = {}
    local cmd_map = {
        BufEnter = M.internal.buf_focus_au_callback,
        FileReadCmd = M.internal.read_au_callback,
        FileWriteCmd = M.internal.write_au_callback,
        BufReadCmd = M.internal.read_au_callback,
        BufWriteCmd = M.internal.write_au_callback,
        BufUnload = M.internal.buf_close_au_callback
    }
    for _, protocol in ipairs(protocols) do
        for command, func in pairs(cmd_map) do
            table.insert(aus, {
                command, {
                    group = 'Netman',
                    pattern = string.format("%s://*", protocol),
                    desc = string.format("Netman %s Autocommand for %s", command, provider.name),
                    callback = func
                }
            })
            log.debug(string.format("Creating Autocommand %s for Provider %s on Protocol %s", command, provider.name, protocol))
        end
    end
    for _, au_command in ipairs(aus) do
        vim.api.nvim_create_autocmd(au_command[1], au_command[2])
    end
end

--- Initializes the Netman Augroups, what did you think it does?
function M.internal.init_augroups()
    vim.api.nvim_create_augroup('Netman', {clear = true})
end

--- Returns the associated config for the config owner.
--- @param config_owner_name string
---     The name of the owner of the config. Name should be the
---     path to the provider/consumer. Note, if there isn't one,
---     already available, **ONE IS NOT CREATED FOR YOU**
---     To get a config created for yourself, you should have registered
---     your provider with netman.api.load_provider. If you're a UI
---     you should be using netman.ui to get your config
--- @return Configuration
function M.internal.get_config(config_owner_name)
    return M.internal.config:get(config_owner_name)
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
            log.warn(string.format("%s provided invalid key: %s, discarding details. To correct this, please remove %s from the provided details", provider, key, key))
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
        log.warn(string.format("%s provided invalid state: %s for host: %s", provider, invalid_state, host))
        valid_entry = false
    end
    ---@diagnostic disable-next-line: return-type-mismatch
    if not valid_entry then return nil else return return_entry end
end

--- Returns a 1 dimensional table of strings which are registered
--- netman providers. Intended to be used with netman.api.providers.get_hosts (but
--- I'm not the police, you do what you want with this).
--- @return table
function M.providers.get_providers()
    local _providers = {}
    for provider, _ in pairs(M._providers.path_to_provider) do
        table.insert(_providers, provider)
    end
    return _providers
end

--- Reaches out to the provided provider and gets a list of
--- the entries it wants displayed
--- @param provider string
---    The string path of the provider in question. This should
---    likely be provided via netman.api.providers.get_providers()
--- @return table/nil
---    Returns a table with data or nil.
---    nil is returned if the provider is not valid or if the provider
---    doesn't have the `get_hosts` function implemented
---    NOTE: Does _not_ validate the schema, you do that yourself, whatever
---    is calling this
function M.providers.get_hosts(provider)
    local _provider = M._providers.path_to_provider[provider]
    local hosts = nil
    if not _provider then
        log.warn(string.format("%s is not a valid provider", provider))
        return hosts
    end
    local _config = M.internal.config:get(provider)
    if not _provider.provider.ui or not _provider.provider.ui.get_hosts then
        log.info(string.format("%s has not implemented the ui.get_hosts function", provider))
        return nil
    else
        local cache = _provider.cache
        _provider = _provider.provider
        hosts = _provider.ui.get_hosts(_config, cache)
    end
    log.debug(string.format("Got hosts for %s", provider), { hosts = hosts })
    return hosts
end

--- Gets details for a specific host
--- @param provider string
---     The path to the provider. For example, `netman.providers.ssh`. This will be provided by netman.api.provider.get_providers
--- @param host string
---     The name of the host. For example `localhost`. This will be provided by the provider via netman.api.providers.get_hosts
--- @return table
---     Returns a 1 dimensional table with the following information
---     - NAME (string)
---     - URI (string)
---     - STATE (string from netman.options.ui.states)
function M.providers.get_host_details(provider, host)
    local _provider = M._providers.path_to_provider[provider]
    if not _provider then
        log.warn(string.format("%s is not a valid provider", provider))
        ---@diagnostic disable-next-line: return-type-mismatch
        return nil
    end
    if not _provider.provider.ui or not _provider.provider.ui.get_host_details then
        log.info(string.format("%s has not implemented the ui.get_host_details function", provider))
        ---@diagnostic disable-next-line: return-type-mismatch
        return nil
    end
    local config = M.internal.config:get(provider)
    if not config then
        log.info(string.format("%s has no configuration associated with it?!", provider))
    end
    local cache = _provider.cache
    _provider = _provider.provider
    local _data = _provider.ui.get_host_details(config, host, cache)
    return M.internal.validate_entry_schema(provider, _data)
end

function M.remove_config(provider)
    if provider and provider:match('^netman%.') then
        print('i BeT iT wOuLd Be FuNnY tO rEmOvE a CoRe CoNfiGuRaTiOn ( ͡°Ĺ̯ ͡° )')
        return
    end
    M.internal.config:del(provider)
    M.internal.config:save()
end

function M.clear_unused_configs(assume_yes)
    local ran = false
    for key, value in pairs(M.internal.config.__data) do
        if key:match('^netman%.') then goto continue end
        ran = true
        local last_loaded = value:get('_last_loaded')
        if not last_loaded or last_loaded < M.internal.boot_timestamp then
            -- Potentially remove the configuration
            if not assume_yes then
                vim.ui.input({
                    prompt = string.format("Remove Stored Configuration For Provider: %s? y/N", key),
                    default = 'N',
                }, function(option)
                    if option == 'y' or option == 'Y' then
                        print(string.format("Removing Netman Configuration: %s", key))
                        M.remove_config(key)
                    else
                        print(string.format("Preserving Netman Configuration: %s", key))
                    end
                end)
            else
                M.remove_config(key)
            end
        end
        ::continue::
    end
    if not ran then print("There are currently no unused netman provider configurations") end
end

--- TODO: Where Doc?
function M.read(uri, opts)
    local orig_uri = uri
    local provider, cache = nil, nil
    uri, provider, cache = M.internal.validate_uri(uri)
    if not uri or not provider then
        return {
            success = false,
            error = string.format("Unable to read %s or unable to find provider for it", orig_uri)
        }
    end
    opts = opts or {}
    log.info(
        string.format("Reaching out to %s to read %s", provider.name, uri)
    )
    if M._providers.file_cache[uri] and not opts.force then
        local cached_file = M._providers.file_cache[uri]
        local _data = {
            data = {
                local_path = cached_file,
                remote_path = uri
            },
            type = netman_options.api.READ_TYPE.FILE
        }
        log.info(string.format("Found cached file %s for uri %s", cached_file, uri))
        log.trace('Short circuiting provider reach out')
        return _data
    end
    local read_data = provider.read(uri, cache)
    if read_data == nil then
        log.info("Received no read_data. I'm gonna get angry!")
        return {
            error = {
                message = "Nil Read Data"
            },
            success = false
        }
    end
    if not read_data.success then
        -- We failed to read data, return the error up
        return read_data
    end
    local read_type = read_data.type
    if netman_options.api.READ_TYPE[read_type] == nil then
        log.warn("Received invalid read type: %s. See :h netman.api.read for read type details", read_type)
        return {
            error = {
                message = "Invalid Read Type"
            },
            success = false
        }
    end
    if not read_data.data then
        log.warn(string.format("No data passed back with read of %s ????", uri))
        return {
            success = true
        }
    end
    local _data = nil
    if read_type == netman_options.api.READ_TYPE.EXPLORE then
        _data = M.internal.sanitize_explore_data(read_data.data)
    elseif read_type == netman_options.api.READ_TYPE.FILE then
        _data = M.internal.sanitize_file_data(read_data.data)
        if not _data.error and _data.local_path then
            log.trace(string.format("Caching %s to local file %s", uri, _data.local_path))
            M._providers.file_cache[uri] = _data.local_path
        end
    elseif read_type == netman_options.api.READ_TYPE.STREAM then
        _data = read_data.data
    end
    local _error = _data.error
    -- Removing error key value from data as it will be a parent level attribute
    _data.error = nil
    return {
        success = true,
        error = _error,
        data = _data,
        type = read_type
    }
end

function M.write(buffer_index, uri, options)
    options = options or {}
    local provider, cache, lines = nil, nil, {}
    uri, provider, cache = M.internal.validate_uri(uri)
    if not uri or not provider then return {success = false, error="Unable to find matching provider, or unable to validate uri!"} end
    log.info(string.format("Reaching out to %s to write %s", provider.name, uri))
    if buffer_index then
        lines = vim.api.nvim_buf_get_lines(buffer_index, 0, -1, false)
        -- Consider making this an iterator instead
        for index, line in ipairs(lines) do
            if not line:match('[\n\r]$') then
                lines[index] = line .. '\n'
            end
        end
    end
    -- TODO: Do this asynchronously
    local status = provider.write(uri, cache, lines, options)
    if not status.success then
        log.warn(string.format("Received error from %s provider while trying to write %s", provider.name, uri), {error=status.error})
        return status
    end
    if not status.uri then
        log.trace("No URI returned on write. Setting the return URI to itself")
        uri = uri
    else
        uri = status.uri
    end
    return {success = true, uri = uri}
end

--- @param uris table
---     A table (a single URI can be a string as well) of URIs that need to be moved
--- @param target_uri string
---     The target location for the URI(s) to be moved to.
--- @return table
---     Returns a table with the following keys,
---     - error (optional)
---         - Only present if there is an error. If so, the value will be the following table
---             - message
---             - callback (optional)
function M.move(uris, target_uri)
    log.trace("MOVE!", {uris=uris, target_uri=target_uri})
    -- Wrapping a single URI in a table so all logic is consistent
    if type(uris) == 'string' then uris = { uris } end
    local grouped_uris = {}
    local _, target_provider, target_cache = M.internal.validate_uri(target_uri)
    if not target_provider then
        -- Something is very much not right
        local _error = string.format("Unable to find provider for %s", target_uri)
        log.error(_error)
        return {
            error = {
                message = _error
            }
        }
    end
    if not target_provider.archive or not target_provider.archive.put then
        local _error = string.format("Target provider for %s did not implement archive.put", target_uri)
        log.error(_error)
        return {
            error = {
                message = _error
            }
        }
    end

    for _, uri in ipairs(uris) do
        local _, provider, cache = M.internal.validate_uri(uri)
        if not provider then
            log.warn(string.format("Unable to find matching provider for %s", uri))
            goto continue
        end
        if not provider.archive or not provider.archive.get then
            log.warn(string.format("Provider for %s did not implement archive.get function", uri))
            goto continue
        end
        if not grouped_uris[provider] then
            grouped_uris[provider] = { uris = {}, cache = cache }
        end
        table.insert(grouped_uris[provider].uris, uri)
        ::continue::
    end
    if grouped_uris[target_provider] then
        if not target_provider.move then
            log.warn(string.format("%s does not support internal moving, attempting to force", target_provider.name))
            goto continue
        end
        local group = grouped_uris[target_provider]
        local target_uris = group.uris

        log.info(string.format("Attempting to move uris internally in provider %s", target_provider.name), {uris=target_uris})
        local move_status = target_provider.move(target_uris, target_uri, target_cache)
        if move_status.success then
            -- The provider was able to interally move the URIs on it, removing them
            -- from the ones that need to be moved
            grouped_uris[target_provider] = nil
            return { success = true }
        end
        ::continue::
    end
    local available_compression_schemes = target_provider.archive.schemes(target_uri, target_cache)
    if available_compression_schemes.error then
        -- Complain that we got an error from the target and bail
        local message = string.format("Received failure while looking for archive schemes for %s", target_uri)
        log.warn(message, available_compression_schemes)
        return { error = available_compression_schemes.error }
    end
    local temp_dir = require("netman.tools.utils").tmp_dir
    -- TODO: Mike
    -- Consider a coroutine for each iteration of this loop and then join those bois together so 
    -- we can properly "utilize" multiprocessing
    for provider, data in pairs(grouped_uris) do
        local archive_data = provider.archive.get(data.uris, data.cache, temp_dir, available_compression_schemes)
        if archive_data.error then
            -- Something happened!
            local message = string.format("Received error while trying to archive uris on %s", provider.name)
            notify.warn(message)
            log.warn(message, archive_data.error)
            -- TODO: Consider a way to let the archival resume on failure if the user wishes...?
            return archive_data
        end
        local status = target_provider.archive.put(target_uri, target_cache, archive_data.archive_path, archive_data.scheme)
        if status.error then
            local message = string.format("Received error from %s while trying to upload archive", target_provider.name)
            notify.warn(message)
            log.warn(message, status)
        end
        for _, uri in ipairs(data.uris) do
            status = provider.delete(uri, data.cache)
            if status.error then
                local message = string.format("Received error during cleanup of %s", uri)
                notify.warn(message)
                log.warn(message, status)
            end
        end
        -- -- Remove the temporary file
        assert(vim.loop.fs_unlink(archive_data.archive_path), string.format("Unable to remove %s", archive_data.archive))
    end
    return {success = true}
end

function M.delete(uri)
    local provider, cache = nil, nil
    uri, provider, cache = M.internal.validate_uri(uri)
    if not uri or not provider then return nil end
    log.info(string.format("Reaching out to %s to delete %s", provider.name, uri))
    -- Do this asynchronously
    provider.delete(uri, cache)
    M._providers.file_cache[uri] = nil
end

function M.get_metadata(uri, metadata_keys)
    local provider, cache = nil, nil
    uri, provider, cache = M.internal.validate_uri(uri)
    if not uri then return nil end
    if not metadata_keys then
        metadata_keys = {}
        for key, _ in pairs(netman_options.explorer.STANDARD_METADATA_FLAGS) do
            table.insert(metadata_keys, key)
        end
    end
    log.trace("Validating Metadata Request", uri)
    local sanitized_metadata_keys = {}
    for _, key in ipairs(metadata_keys) do
        if not netman_options.explorer.METADATA[key] then
            log.warn("Metadata Key: " ..
                tostring(key) ..
                " is not valid. Please check `https://github.com/miversen33/netman.nvim/wiki/API-Documentation#get_metadatarequested_metadata` for details on how to properly request metadata")
        else
            table.insert(sanitized_metadata_keys, key)
        end
    end
    local provider_metadata = provider.get_metadata(uri, cache, sanitized_metadata_keys) or {}
    local metadata = {}
    for _, key in ipairs(sanitized_metadata_keys) do
        metadata[key] = provider_metadata[key] or nil
    end
    return metadata
end

-- TODO: (Mike): Do a thing with this?
function M.unload_buffer(uri, buffer_handle)
    M._providers.file_cache[uri] = nil
end

--- Unload Provider is a function that is provided to allow a user (developer)
--- to remove a provider from Netman. This is most useful when changes have been
--- made to the provider and you wish to reflect those changes without
--- restarting Neovim
--- @param provider_path string
---    The string path to the provider
---    EG: "netman.provider.ssh"
--- @return nil
function M.unload_provider(provider_path, justification)
    local justified = false
    if justification then justified = true end
    log.info("Attempting to unload provider: " .. provider_path)
    local status, provider = pcall(require, provider_path)
    if not status or provider == true or provider == false then
        log.warn("Failed to fetch provider " .. provider_path .. " for unload!")
        return
    end
    package.loaded[provider_path] = nil
    if provider.protocol_patterns then
        log.info("Disassociating Protocol Patterns and Autocommands with provider: " .. provider_path)
        for _, pattern in ipairs(provider.protocol_patterns) do
            local _, _, new_pattern = pattern:find(protocol_pattern_sanitizer_glob)
            if M._providers.protocol_to_path[new_pattern] then
                log.trace("Removing associated autocommands with " .. new_pattern .. " for provider " .. provider_path)
                if not justified then
                    justification = {
                        reason = "Provider Unloaded"
                        , name = provider_path
                        , protocol = table.concat(provider.protocol_patterns, ', ')
                        , version = provider.version
                    }
                    justified = true
                end
                M._providers.protocol_to_path[new_pattern] = nil
            end
        end
    end
    M._providers.path_to_provider[provider_path] = nil
    M._providers.uninitialized[provider_path] = justification
end

--- Load Provider is what a provider should call
--- (via require('netman.api').load_provider) to load yourself
--- into netman and be utilized for uri resolution in other
--- netman functions.
--- @param provider_path string
---    The string path to the provider
---    EG: "netman.provider.ssh"
--- @return nil
function M.load_provider(provider_path)
    if M._providers.path_to_provider[provider_path] then
        log.warn(string.format("%s is already loaded! Consider calling require('netman.api').reload_provider('%s') if you want to reload it"
            , provider_path, provider_path))
        return
    end
    local status, provider = pcall(require, provider_path)
    log.info("Attempting to import provider: " .. provider_path)
    if not status or provider == true or provider == false then
        log.info("Received following info on attempted import", { status = status, provider = provider })
        notify.error("Failed to initialize provider: " ..
            tostring(provider_path) ..
            ". This is likely due to it not being loaded into neovim correctly. Please ensure you have installed this plugin/provider")
        return
    end
    log.info("Validating Provider: " .. provider_path)
    local missing_attrs = nil
    for _, required_attr in ipairs(_provider_required_attributes) do
        if not provider[required_attr] then
            if missing_attrs then
                missing_attrs = missing_attrs .. ', ' .. required_attr
            else
                missing_attrs = required_attr
            end
        end
    end
    log.info("Validation finished")
    if missing_attrs then
        log.error("Failed to initialize provider: " ..
            provider_path .. ". Missing the following required attributes (" .. missing_attrs .. ")")
        M._providers.uninitialized[provider_path] = {
            reason = string.format("Validation Failure: Missing attribute(s) %s", missing_attrs)
            , name = provider_path
            , protocol = "Unknown"
            , version = "Unknown"
        }
        return
    end
    log.trace("Initializing " .. provider_path .. ":" .. provider.version)
    M._providers.path_to_provider[provider_path] = { provider = provider,
        cache = cache_generator:new(cache_generator.MINUTE) }
    -- TODO(Mike): Figure out how to load configuration options for providers
    local provider_config = M.internal.config:get(provider_path)
    if not provider_config then
        provider_config = require("netman.tools.configuration"):new()
        provider_config.save = function(_) M.internal.config:save() end
        M.internal.config:set(provider_path, provider_config)
    end
    provider_config:set('_last_loaded', vim.loop.now())
    M.internal.config:save()
    if provider.init then
        -- Consider having this being a timeout based async job?
        -- Bad actors will break the plugin altogether
        local valid = nil
        status, valid = pcall(
            provider.init
            , provider_config
            , M._providers.path_to_provider[provider_path].cache
        )
        if not status or valid ~= true then
            log.warn(string.format("%s:%s refused to initialize. Discarding", provider_path, provider.version), valid)
            M.unload_provider(provider_path, {
                reason = "Initialization Failed"
                , name = provider_path
                , protocol = table.concat(provider.protocol_patterns, ', ')
                , version = provider.version
                , error = valid
            })
            return
        end
    end

    for _, pattern in ipairs(provider.protocol_patterns) do
        local _, _, new_pattern = pattern:find(protocol_pattern_sanitizer_glob)
        log.trace("Reducing " .. pattern .. " down to " .. new_pattern)
        local existing_provider_path = M._providers.protocol_to_path[new_pattern]
        if existing_provider_path then
            local existing_provider = M._providers.path_to_provider[existing_provider_path].provider
            if provider_path:find('^netman%.providers') then
                log.trace(
                    "Core provider: "
                    .. provider.name
                    .. ":" .. provider.version
                    .. " attempted to override third party provider: "
                    .. existing_provider.name
                    .. ":" .. existing_provider.version
                    .. " for protocol pattern "
                    .. new_pattern .. ". Refusing...")
                M._providers.uninitialized[provider_path] = {
                    reason = "Overriden by " .. existing_provider_path .. ":" .. existing_provider.version
                    , name = provider_path
                    , protocol = table.concat(provider.protocol_patterns, ', ')
                    , version = provider.version
                }
                goto exit
            end
            log.info("Provider " .. existing_provider_path .. " is being overriden by " .. provider_path)
            M.unload_provider(existing_provider_path, {
                reason = "Overriden by " .. provider_path .. ":" .. provider.version
                , name = existing_provider.name
                , protocol = table.concat(existing_provider.protocol_patterns, ', ')
                , version = existing_provider.version
            })
        end
        M._providers.protocol_to_path[new_pattern] = provider_path
    end
    M._providers.uninitialized[provider_path] = nil
    M.internal.init_provider_autocmds(provider, provider.protocol_patterns)
    log.info("Initialized " .. provider_path .. " successfully!")
    ::exit::
end

function M.reload_provider(provider_path)
    M.unload_provider(provider_path)
    M.load_provider(provider_path)
end

function M.init()
    if M._inited then
        log.info("Netman API already initialized!")
        return
    end
    log.info("--------------------Netman API initialization started!---------------------")
    log.info("Creating Netman augroup")
    vim.api.nvim_create_augroup('Netman', {clear = true})
    M.internal.init_config()
    local core_providers = require("netman.providers")
    for _, provider in ipairs(core_providers) do
        M.load_provider(provider)
    end
    M._inited = true
    log.info("--------------------Netman API initialization complete!--------------------")
end

M.init()
return M
