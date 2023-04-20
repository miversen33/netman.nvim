-- TODO: (Mike): MOAR LOGS
local utils = require("netman.tools.utils")
local netman_options = require("netman.tools.options")
local cache_generator = require("netman.tools.cache")
local logger = require("netman.tools.utils").get_system_logger()
local rand_string = require("netman.tools.utils").generate_string
local compat = require("netman.tools.compat")

local M = {}

--- WARN: Do not rely on these functions existing
--- WARN: Do not use these functions in your code
--- WARN: If you put an issue in saying anything about using
--- these functions is not working in your plugin, you will
--- be laughed at and ridiculed
M.internal = {
    config = require("netman.tools.configuration"):new(),
    -- This will be used to help track unused configurations
    boot_timestamp = vim.loop.now(),
    config_path = require("netman.tools.utils").data_dir .. '/providers.json',
    -- Used to track callbacks for events
    events = {
        -- Ties ids to callbacks
        handler_map = {},
        -- Ties events to ids to callback
        event_map = {}
    }
}

M.get_provider_logger = function()
    return require("netman.tools.utils").get_provider_logger()
end

M.get_consumer_logger = function()
    return require("netman.tools.utils").get_consumer_logger()
end

M.get_system_logger = function() return logger end

--- Set of tools to communicate directly with provider(s) (in a generic sense).
--- Note, this will not let you talk directly to the provider per say, (meaning you can't
--- talk straight to the ssh provider, but you can talk to api and tell it you want things
--- from or to give to the ssh provider).
M.providers = {}

--- The default function that any provider configuration will have associated with its
--- :save function.
M.internal.config.save = function(self)
    local _config = io.open(M.internal.config_path, 'w+')
    if not _config then
        error(string.format("Unable to write to netman configuration: %s",
            M.internal.config_path))
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

M.version = 1.01

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
function M.internal.wrap_shell_handle(handle)
    local return_handle = {
        async    = true,
        read     = nil,
        write    = nil,
        stop     = nil,
        _handle  = handle,
        _stopped = false
    }

    function return_handle.read(pipe)
        return return_handle._handle and return_handle._handle.read(pipe)
    end

    function return_handle.write(data)
        return return_handle._handle and return_handle._handle.write(data)
    end

    function return_handle.stop(force)
        return_handle._stopped = true
        return return_handle._handle and return_handle._handle.stop(force)
    end

    return return_handle
end

--- WARN: Do not rely on these functions existing
--- WARN: Do not use these functions in your code
--- WARN: If you put an issue in saying anything about using
--- these functions is not working in your plugin, you will
--- be laughed at and ridiculed
function M.internal.init_config()
    local _lines = {}
    local _config = io.open(M.internal.config_path, 'r+')
    if _config then
        for line in _config:lines() do table.insert(_lines, line) end
        _config:close()
        if next(_lines) then
            logger.trace("Decoding Netman Configuration")
            local success = false
            success, _config = pcall(vim.fn.json_decode, _lines)
            if not success then
                _config = {}
            end
        else
            _config = {}
        end
    else
        logger.infof("No netman configuration found at %s", M.internal.config_path)
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

    logger.trace("Loaded Configuration")
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
        logger.warn(string.format("%s is not ours to deal with", uri))
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
---     A 1 dimensional table
--- @return table
function M.internal.sanitize_explore_data(read_data)
    local sanitized_data = {}
    for _, orig_data in pairs(read_data) do
        if type(orig_data) ~= 'table' then
            logger.warn("Invalid data found in explore data", {key = _, value = orig_data})
            goto continue
        end
        local data = utils.deep_copy(orig_data)
        for key, value in pairs(data) do
            if netman_options.explorer.FIELDS[key] == nil then
                logger.infof("Removing %s from directory data as it " ..
                    "does not conform with netman.options.explorer.FIELDS...", key)
                data[key] = nil
            elseif key == netman_options.explorer.FIELDS.METADATA then
                for _metadata_flag, _ in pairs(value) do
                    if netman_options.explorer.METADATA[_metadata_flag] == nil then
                        logger.warnf("Removing metadata flag " .. _metadata_flag .. " from items metadata as it " ..
                            "does not conform with netman.options.explorer.METADATA...")
                        value[_metadata_flag] = nil
                    end
                end
            end
        end
        if not next(data) then
            logger.warn("Nothing to validate in data, skipping to next item")
            goto continue
        end
        local acceptable_output = true
        for _, field in ipairs(netman_options.explorer.FIELDS) do
            if data[field] == nil then
                logger.warn("Explorer Data Missing Required Field: " .. field)
                acceptable_output = false
            end
        end
        if acceptable_output then
            table.insert(sanitized_data, data)
        end
        ::continue::
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
    logger.trace("Validating Read File Data", read_data)
    local REQUIRED_KEYS = { 'local_path', 'origin_path' }
    if read_data.error then
        logger.warn("Received error from read attempt. Returning error")
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
        logger.warn("Read Data was missing the following required keys", MISSING_KEYS)
        ---@diagnostic disable-next-line: return-type-mismatch
        return nil
    end
    return read_data
end

function M.internal.read_au_callback(callback_details)
    local uri = callback_details.match
    if M.internal.get_provider_for_uri(uri) then
        logger.trace(string.format("Reading %s", uri))
        require("netman").read(uri)
        return
    end
    logger.warn(string.format("Cannot find provider match for %s | Unable to read %s", uri, uri))
end

function M.internal.write_au_callback(callback_details)
    -- For some reason, providers aren't being found on write?
    logger.debug({callback=callback_details})
    local uri = callback_details.match
    if M.internal.get_provider_for_uri(uri) then
        logger.trace(string.format("Writing contents of buffer to %s", uri))
        require("netman").write(uri)
        return
    end
    logger.warn(string.format("Cannot find provider match for %s | Unable to write to %s", uri, uri))
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
    logger.info(string.format("Cannot find provider match for %s | It appears that the uri was abandoned?", uri))
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
            logger.debug(string.format("Creating Autocommand %s for Provider %s on Protocol %s", command, provider.name, protocol))
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
            logger.warn(string.format("%s provided invalid key: %s, discarding details. To correct this, please remove %s from the provided details", provider, key, key))
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
        logger.warn(string.format("%s provided invalid state: %s for host: %s", provider, invalid_state, host))
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
        logger.warn(string.format("%s is not a valid provider", provider))
        return hosts
    end
    local _config = M.internal.config:get(provider)
    if not _provider.provider.ui or not _provider.provider.ui.get_hosts then
        logger.info(string.format("%s has not implemented the ui.get_hosts function", provider))
        return nil
    else
        local cache = _provider.cache
        _provider = _provider.provider
        hosts = _provider.ui.get_hosts(_config, cache)
    end
    logger.debug(string.format("Got hosts for %s", provider), { hosts = hosts })
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
---     - ENTRYPOINT (table of URIs, or a function to call to get said table of URIs)
function M.providers.get_host_details(provider, host)
    local _provider = M._providers.path_to_provider[provider]
    if not _provider then
        logger.warn(string.format("%s is not a valid provider", provider))
        ---@diagnostic disable-next-line: return-type-mismatch
        return nil
    end
    if not _provider.provider.ui or not _provider.provider.ui.get_host_details then
        logger.info(string.format("%s has not implemented the ui.get_host_details function", provider))
        ---@diagnostic disable-next-line: return-type-mismatch
        return nil
    end
    local config = M.internal.config:get(provider)
    if not config then
        logger.info(string.format("%s has no configuration associated with it?!", provider))
    end
    local cache = _provider.cache
    _provider = _provider.provider
    local _data = _provider.ui.get_host_details(config, host, cache)
    return M.internal.validate_entry_schema(provider, _data)
end

function M.internal.remove_config(provider)
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
                        M.internal.remove_config(key)
                    else
                        print(string.format("Preserving Netman Configuration: %s", key))
                    end
                end)
            else
                M.internal.remove_config(key)
            end
        end
        ::continue::
    end
    if not ran then print("There are currently no unused netman provider configurations") end
end

--- Attempts to execute a connection event on the underlying
--- provider for the provided URI. Note, successful
--- connection to the URI host (per the provider) will trigger
--- a `netman_provider_host_connect` event
--- @param uri: string
---     The string URI to connect to
--- @param callback: function | Optional
---     If provided, indicates that the connection event
---     should be asynchronous if possible.
---     NOTE: Even if it is impossible to asynchronously execute
---     the connection, the response will still be provided
---     via the callback as that is what is expected by the end user
--- @return table | boolean
---     If an error is encountered while trying to execute the
---     connection event, a table will be returned with the following structure
---     {
---         message: string,
---         -- Whatever the message is,
---         process: function | Optional,
---         -- If this is provided, call this function with whatever
---         -- response the user provides to the message that was provided
---         is_error: boolean | Optional
---         -- If provided, indicates that the message is an error
---     }
---     
---     If the requested connection event is synchronous, this will
---     simply return the boolean (T/F) response from the provider
---     after completing the connection request
---     
---     If the requested connection event was asynchronous, this will
---     return a table that contains the following key/value pairs
---     {
---         read: function,
---         -- Takes an optional string parameter that can be
---         -- "STDERR", or "STDOUT" to indicate which pipe to read from.
---         -- Defaults to "STDOUT"
---         write: function,
---         -- Takes a string or table of data to write to the
---         -- underlying handle
---         stop: function
---         -- Takes an optional boolean to indicate the stop should
---         -- be forced
---     }
function M.connect_to_uri_host(uri, callback)
    local orig_uri = uri
    local provider, cache = nil, nil
    uri, provider, cache = M.internal.validate_uri(uri)
    if not uri or not provider then
        local msg = string.format("Unable to find provider for %s, cannot execute connection", orig_uri)
        logger.warn(msg)
        local response = { message = msg, is_error = true }
        if callback then
            callback(response)
            return
        else
            return response
        end
    end
    if not provider.connect_host then
        local msg = string.format("Provider %s does not report a `close_host` function. Unable to manually connect host of %s", provider.name, uri)
        logger.warn(msg)
        local response = { message = msg, is_error = true }
        if callback then
            callback(response)
            return
        else
            return response
        end
    end
    logger.debugf("Reaching out to %s to connect to the host of %s", provider.name, uri)
    local handle = nil
    if callback then
        if not provider.connect_host_a then
            logger.warnf("Provider %s does not support asynchronous host connection", provider.name)
            callback(provider.connect_host(uri, cache))
            return
        else
            logger.tracef("Attempting asynchronous connection to host of %s", uri)
            handle = provider.connect_host_a(uri, cache, callback)
            if not handle then
                logger.warnf("Provider %s did not provide a handle for asynchronous host connection. Removing the ability to asynchronously connect to hosts")
                provider.connect_host_a = nil
                callback()
                return
            end
            if handle.message then
                -- This is an error response and _not_ what we are expecting
                logger.warn("Received message instead of async handle", { message = handle.message, is_error = handle.is_error})
                callback(handle)
                return
            end
            local wrapped_handle = M.internal.wrap_shell_handle(handle)
            if not wrapped_handle then
                logger.warnf("Provider %s returned an invalid handle for asynchronous connect. Removing the ability to asynchronously connect hosts")
                provider.connect_host_a = nil
                callback()
                return
            end
            M.emit_event('netman_provider_host_connect', 'netman.api.connect_to_uri_host')
            return wrapped_handle
        end
    end
    M.emit_event('netman_provider_host_connect', 'netman.api.connect_to_uri_host')
    return provider.connect_host(uri, cache)
end

--- Attempts to execute a disconnection event on the underlying
--- provider for the provided URI. Note, successful
--- disconnection from the URI host (per the provider) will trigger
--- a `netman_provider_host_disconnect` event
--- @param uri: string
---     The string URI to disconnect from
--- @param callback: function | Optional
---     If provided, indicates that the disconnection event
---     should be asynchronous if possible.
---     NOTE: Even if it is impossible to asynchronously execute
---     the disconnection, the response will still be provided
---     via the callback as that is what is expected by the end user
--- @return table | boolean
---     If an error is encountered while trying to execute the
---     disconnection event, a table will be returned with the following structure
---     {
---         message: string,
---         -- Whatever the message is,
---         process: function | Optional,
---         -- If this is provided, call this function with whatever
---         -- response the user provides to the message that was provided
---         is_error: boolean | Optional
---         -- If provided, indicates that the message is an error
---     }
---     
---     If the requested disconnection event is synchronous, this will
---     simply return the boolean (T/F) response from the provider
---     after completing the disconnection request
---     
---     If the requested disconnection event was asynchronous, this will
---     return a table that contains the following key/value pairs
---     {
---         read: function,
---         -- Takes an optional string parameter that can be
---         -- "STDERR", or "STDOUT" to indicate which pipe to read from.
---         -- Defaults to "STDOUT"
---         write: function,
---         -- Takes a string or table of data to write to the
---         -- underlying handle
---         stop: function
---         -- Takes an optional boolean to indicate the stop should
---         -- be forced
---     }
function M.disconnect_from_uri_host(uri, callback)
    local orig_uri = uri
    local provider, cache = nil, nil
    uri, provider, cache = M.internal.validate_uri(uri)
    if not uri or not provider then
        local msg = string.format("Unable to find provider for %s, cannot execute disconnection", orig_uri)
        logger.warn(msg)
        local response = { message = msg, is_error = true }
        if callback then
            callback(response)
            return
        else
            return response
        end
    end
    if not provider.close_host then
        local msg = string.format("Provider %s does not report a `close_host` function. Unable to disconnect host of %s", provider.name, uri)
        logger.warn(msg)
        local response = { message = msg, is_error = true }
        if callback then
            callback(response)
            return
        else
            return response
        end
    end
    logger.debugf("Reaching out to %s to disconnect the host of %s", provider.name, uri)
    local handle = nil
    if callback then
        if not provider.close_host_a then
            logger.warnf("Provider %s does not support asynchronous host disconnection", provider.name)
            callback(provider.close_host(uri, cache))
            return
        else
            handle = provider.close_host_a(uri, cache)
            if not handle then
                logger.warnf("Provider %s did not provide a handle for asynchronous host disconnection. Removing the ability to asynchronously disconnect hosts")
                provider.close_host_a = nil
                callback()
                return
            end
            if handle.message then
                -- This is an error response and _not_ what we are expecting
                logger.warn("Received message instead of async handle", { message = handle.message, is_error = handle.is_error })
                callback(handle)
                return
            end
            local wrapped_handle = M.internal.wrap_shell_handle(handle)
            if not wrapped_handle then
                logger.warnf("Provider %s returned an invalid handle for asynchronous disconnect. Removing the ability to asynchronously disconnect hosts")
                provider.close_host_a = nil
                callback()
                return
            end
            M.emit_event('netman_provider_host_disconnect', 'netman.api.disconnect_from_uri_host')
            return wrapped_handle
        end
    end
    M.emit_event('netman_provider_host_disconnect', 'netman.api.disconnect_from_uri_host')
    return provider.close_host(uri, cache)
end

--- Attempts to reach out to the provider
--- to verify if the URI has a connected host
--- @param uri: string
---     The string URI to check
--- @param provider: table | Optional
---     For internal use only, used to bypass uri validation
--- @param cache: table | Optional
---     For internal use only, used to bypass uri validation
--- @return boolean
---     Will return True if (and only if) the provider
---     explicitly informed us that the URI was connected.
---     Failure to connect to the provider for this check,
---     or a false response from the provider will both return
---     false on this call
function M.has_connection_to_uri_host(uri, provider, cache)
    local orig_uri = uri
    if not provider or not cache then
        uri, provider, cache = M.internal.validate_uri(uri)
    end
    if not uri or not provider then
        logger.warnf("Unable to find provider for %s, cannot verify connection status", orig_uri)
        return nil
    end
    if not provider.is_connected then
        logger.infof("Provider %s does not report an `is_connected` function. Unable to verify connection status of %s", provider.name, uri)
        return false
    end
    logger.debugf("Reaching out to %s to verify connection status of %s", provider.name, uri)
    return provider.is_connected(uri, cache)
end

--- WARN: Do not rely on these functions existing
--- WARN: Do not use these functions in your code
--- WARN: If you put an issue in saying anything about using
--- these functions is not working in your plugin, you will
--- be laughed at and ridiculed
--- @param uri string
---     The uri to read
--- @param provider table
---     The provider to execute asynchronous read against
--- @param cache netman.tools.Cache
---     The provider's cache
--- @param is_connected boolean
---     A boolean indicating if the provider already has
---     a connection established for this uri
--- @param output_callback function
---     A callback to call for any output received
---     as well as when we are complete
---     We expect this function to have the following signature
---     output_callback(output_data: table, read_complete: boolean)
--- @param force boolean
---     If provided, will ignore any cache results we might
---     have for the read, and will inform the provider it should
---     do the same
--- @return table | boolean
---     If there is a failure in starting the async command (due to invalid
---     params or the provider being unable to run asynchronously), this
---     will return `false`. Otherwise the below table is returned
---     {
---         async: boolean,
---         -- A boolean to indicate if the read command was
---         -- asynchronously ran.
---         -- NOTE: This does _not_ indicate success
---         success: boolean,
---         -- A boolean to indicate if the read command was successful
---         -- NOTE: this does _not_ indicate if the command
---         -- was async or not
---         handle: table (Optional),
---         -- A table that contains the following items related to the current
---         -- asynchronous running process
---         --     {
---         --         read(pipe): function,
---         --         -- A function that can be called
---         --         -- to read from the the pipe defined.
---         --         -- Valid pipes:
---         --         -- - 'STDOUT' (Default if nil provided)
---         --         -- - 'STDERR'
---         --         write(data): function,
---         --         -- A function that can be called to write
---         --         -- input to the current process.
---         --         stop(force): function
---         --         -- A function that can be called to stop the process
---         --    }
---         error: table (Optional),
---         -- A table that if returned will contain any errors that arose
---         -- during the async startup. If this exists, it will be in the following
---         -- format
---         --    {
---         --        message: string
---         --    }
---     }
function M.internal._read_async(uri, provider, cache, is_connected, output_callback, force)
    local required_async_commands = {'read_a'}
    if not provider then
        logger.errorf("No provider provided for %s", uri)
        return false
    end
    for _, cmd in ipairs(required_async_commands) do
        if not provider[cmd] then
            logger.errorf("Provider %s is missing async command %s", provider.name, cmd)
            return false
        end
    end
    local opts = {}
    opts.force = force
    local protected_callback = function(data, complete)
        local success, error = pcall(output_callback, data, complete)
        if not success then
            logger.warn("Async output processing experienced a failure!", error)
        end
    end
    local return_handle = M.internal.wrap_shell_handle()
    opts.callback = function(data, complete, _force)
        -- Short circuit in case we are killed while still processing
        if return_handle._stopped then return end
        -- If _force is provided, we will return whatever was
        -- provided to us. This is useful internally only.
        -- Check to see if data has a handle attribute. If it does
        -- replace our existing handle reference with that one
        if data and data.handle then
            logger.debug("Received new handle reference from provider during async read. Updating our handle pointer")
            return_handle._handle = data.handle
            return
        end
        if _force then
            protected_callback(data, complete)
            return
        end
        if complete and not data then
            -- There is nothing of substance passed,
            -- but the complete flag was provided.
            -- Call the consumer's complete handle and return
            protected_callback(nil, complete)
            return
        end
        if not netman_options.api.READ_TYPE[data.type] then
            logger.warnf("Unable to trust data type %s. Sent from provider %s while trying to read %s", data.type or 'nil', provider.name, uri)
            return
        end
        if not data.data then
            logger.warnf("Provider %s did not pass back anything useful when requesting asynchronous read of %s", provider.name, uri)
        end
        local return_data = nil
        if data.type == netman_options.api.READ_TYPE.EXPLORE then
            -- Handle "directory" style data
            return_data = M.internal.sanitize_explore_data({data.data})
        elseif data.type == netman_options.api.READ_TYPE.FILE then
            -- Handle "file" style data
            return_data = M.internal.sanitize_file_data(data.data)
            if not return_data then
                local message = string.format("Provider %s did not return valid return data for %s", provider.name, uri)
                logger.warn(message, { return_data = data.data })
                return
            end
            if not return_data.error and return_data.local_path then
                logger.tracef("Caching %s to local file %s", uri, return_data.local_path)
                M._providers.file_cache[uri] = return_data.local_path
            end
        else
            -- Handle "stream" style data
            return_data = data.data
        end
        protected_callback({data = return_data, type = data.type}, complete)
    end

    local do_provider_read = function()
        if return_handle._stopped then
            -- Figure out what we are returning?
            logger.tracef("Read process for %s was stopped externally. Escaping read", uri)
            opts.callback(nil, true)
            return
        end
        logger.tracef("Executing asynchronous read of %s with %s", uri, provider.name)
        local response = provider.read_a(uri, cache, opts.callback)
        if not response then
            logger.errorf("Provider %s did not return anything for async read of %s. First of all, how dare you", provider.name, uri)
            return
        end
        if not response.handle then
            if response.success == false then
                local message = response.message or {
                    message = string.format("Provider %s reported failure while trying to read %s", provider.name, uri)
                }
                logger.warn(string.format("Received failure while trying to read %s from %s. Error: ", uri, provider.name), message.message)
                opts.callback(message, true, true)
                return
            end
            logger.errorf("Provider %s did not return a handle on asynchronous read of %s. Disabling async for this provider in the future...", provider.name, uri)
            provider.read_a = nil
            -- Check to see if we received synchronous output
            if not response.success then
                logger.warnf("Provider %s synchronously failed during async read of %s. Yes I know that makes no sense. You're telling me...", provider.name, uri)
                opts.callback(response, true, true)
                return
            end
            if not response.data then
                logger.warnf("No data passed back with read of %s ????", uri)
                opts.callback(nil, true)
            end
            opts.callback(response, true)
            return
        end
        return_handle._handle = response.handle
    end

    if not is_connected and provider.connect_host_a then
        logger.infof("Attempting provider %s connect to %s", provider.name, uri)
        -- connect to the uri, return a valid return and chain off the
        -- proper exit
        local handle = provider.connect_host_a(
            uri,
            cache,
            function(success)
                if not success then
                    logger.warnf("Provider %s did not indicate success on connect to host of %s", provider.name, uri)
                end
                do_provider_read()
            end
        )
        if not handle then
            logger.warnf("Provider %s did not provide a proper async handle for asynchronous connection event. Removing async connect host", provider.name)
            provider.connect_host_a = nil
        end
        return_handle = M.internal.wrap_shell_handle(handle)
    else
        do_provider_read()
    end
    return return_handle
end

function M.internal._read_sync(uri, provider, cache, is_connected, force)
    assert(provider, "No provider provided to read")
    if not is_connected and provider.connect then
        local connected = provider.connect(uri)
        if not connected then
            logger.warnf("Provider %s did not indicate success on connect to host of %s", provider.name, uri)
        end
    end
    logger.infof("Reaching out to %s to read %s", provider.name, uri)
    local read_data = provider.read(uri, cache)
    logger.trace(string.format("Received Output from read of %s", uri), read_data)
    if not read_data then
        logger.warnf("Provider %s did not return read data for %s. I'm gonna get angry!", provider.name, uri)
        return {
            message = {
                message = 'Nil Read Data'
            },
            success = false
        }
    end
    if not read_data.success then
        logger.warn(string.format("Provider %s reported a failure in the read of %s", provider.name, uri), {response = read_data})
        return {
            message = read_data.message,
            success = false
        }
    end
    if not netman_options.api.READ_TYPE[read_data.type] then
        local message = string.format("Provider %s returned invalid read type %s. See :h netman.api.read for read type details", provider.name, read_data.type or 'nil')
        logger.warn(message)
        return {
            success = false,
            message = { message = message }
        }
    end
    if not read_data.data then
        logger.warnf("No data passed back with read of %s ????", uri)
        return {
            success = false,
            message = { message = string.format("Unable to read %s. Check :Nmlogs for details", uri)}
        }
    end
    local return_data = nil
    if read_data.type == netman_options.api.READ_TYPE.EXPLORE then
        return_data = M.internal.sanitize_explore_data(read_data.data)
        if not return_data or (#return_data == 0 and next(read_data.data)) then
            logger.warn("It looks like all provided data on read was sanitized. The provider most likely returned bad data. Provided Data -> ", read_data.data)
            return {
                success = false,
                message = {
                    message = string.format("Received invalid data on read of %s", uri)
                }
            }
        end
    elseif read_data.type == netman_options.api.READ_TYPE.FILE then
        return_data = M.internal.sanitize_file_data(read_data.data)
    else
        return_data = read_data.data
    end
    local _error = return_data.error
    return_data.error = nil
    return {
        success = _error and false or true,
        message = _error and { message  = _error },
        async = false,
        data = return_data,
        type = read_data.type
    }
end

--- Executes remote read of uri
--- NOTE: Read also caches results for a short time, and will
--- return those cached results instead of repeatedly reaching
--- out to the underlying provider for repeat requests.
--- @param uri string
---     The string representation of the remote resource URI
--- @param opts table | Optional
---     Default: {}
---     Options to provide to the provider. Valid options include
---     - force: boolean
---         If provided, indicates that we should invalidate any cached
---         instances of the URI before pull
--- @param callback function | Optional
---     Default: nil
---     If provided, we will attempt to treate the read request as asynchronous.
---     NOTE: this affects the return value!
--- @return table
---     If the read request is asynchronous, you will recieve the following table
---     {
---         async: boolean,
---         -- A boolean that should be set to true to indicate that
---         -- the read request is asynchronously being completed
---         read: function,
---         -- Takes an optional string parameter that can be
---         -- "STDERR", or "STDOUT" to indicate which pipe to read from.
---         -- Defaults to "STDOUT"
---         write: function,
---         -- Takes a string or table of data to write to the
---         -- underlying handle
---         stop: function
---         -- Takes an optional boolean to indicate the stop should
---         -- be forced
---     }
---     Note, the synchronous output below will be provided to the callback param
---     as a parameter to it instead, with the exception of the following keys
---     - async, success
---     Its pretty obvious that the results are async as they are being streamed to
---     you, and success is also obvious if you are receiving the output
---     
---     If the read request is synchronous, you will receive the following table
---     {
---         async: boolean,
---         -- A boolean that should be set to false to indicate that
---         -- the read request was synchronously completed
---         success: boolean,
---         -- A boolean indicating if the read was successfully completed
---         type: string,
---         -- A string indicating what type of result you will receive. Valid
---         -- types are
---         -- - "EXPLORE"
---         --     -- Indicates a directory style set of data. This
---         --     -- means the `data` key will be a 1 dimensional array
---         --     -- containing a stat table for each item returned
---         -- - "FILE"
---         --     -- Indicates an individual file type of data. This
---         --     -- means that there is a file located somewhere on the host
---         --     -- machine that is the result of whatever was pulled down
---         --     -- from the URI. `data` will be formatted in the following manner
---         --     -- {
---         --            local_path: string,
---         --                -- The local path to the downloaded file
---         --            origin_path: string,
---         --                -- The remote path that was read for this file
---         --     -- }
---         -- - "STREAM"
---         --     -- Indicates a stream of data. This means that there
---         --     -- is no data stored locally and and such `data` will be
---         --     -- a 1 dimensional array of "lines" of output
---         data: table,
---         -- See `type` for details on how this table will be formatted,
---         -- based on the type of data returned by the provider
---         message: table | Optional,
---         -- An optional table that may be returned by the provider.
---         -- If this table exists, it will be in the following format
---         -- {
---         --     message: string,
---         --     -- The message to relay to the consumer
---         --     process: function | Optional,
---         --     -- If provided, indicates that the provider expects
---         --     -- the message to be an input prompt of some kind.
---         --     -- Call process with the result of the prompt so the
---         --     -- provider can continue with whatever it was doing.
---         --     -- NOTE: This will return a table with the following info
---         --     -- {
---         --     --     retry: boolean,
---         --     --     -- Indicates if you should recall the original function
---         --     --     -- call again. IE, if true, call api.read again
---         --     --     -- with the original params
---         --     --     message: string | Optional
---         --     --     -- The message printed during the retry. Usually
---         --     --     -- this indicates a complete failure of the call and
---         --     --     -- retry logic altogether
---         --     -- }
---         --     default: string | Optional,
---         --     -- If provided, indicates the default value to put
---         --     -- in for whatever the prompt is that was provided with
---         --     -- the message key
---         -- }
---     }
function M.read(uri, opts, callback)
    local orig_uri = uri
    local provider, cache, is_connected = nil, nil, nil
    uri, provider, cache, _ = M.internal.validate_uri(uri)
    if not uri or not provider then
        return {
            success = false,
            error = string.format("Unable to read %s or unable to find provider for it", orig_uri)
        }
    end
    opts = opts or {}
    logger.info(
        string.format("Reaching out to %s to read %s", provider.name, uri)
    )
    if M._providers.file_cache[uri] and not opts.force then
        local cached_file = M._providers.file_cache[uri]
        local _data = {
            data = {
                local_path = cached_file,
                remote_path = uri
            },
            type = netman_options.api.READ_TYPE.FILE,
            success = true
        }
        logger.infof("Found cached file %s for uri %s", cached_file, uri)
        logger.trace('Short circuiting provider reach out')
        return _data
    end
    is_connected = M.has_connection_to_uri_host(uri, provider, cache)
    if callback and provider.read_a then
        logger.infof("Attempting asynchronous read of %s", uri)
        return M.internal._read_async(uri, provider, cache, is_connected, callback, opts.force)
    else
        logger.infof("Attempting synchronous read of %s", uri)
        return M.internal._read_sync(uri, provider, cache, is_connected, opts.force)
    end
end

function M.internal._write_async(uri, provider, cache, is_connected, lines, output_callback)
    local required_async_commands = {'write_a'}
    if not provider then
        logger.errorf("No provider provided for %s", uri)
        return false
    end
    for _, cmd in ipairs(required_async_commands) do
        if not provider[cmd] then
            logger.errorf("Provider %s is missing async command %s", provider.name, cmd)
            return false
        end
    end
    local opts = {}
    local protected_callback = function(data, complete)
        local success, error = pcall(output_callback, data, complete)
        if not success then
            logger.warn("Async output processing experienced a failure!", error)
        end
    end
    local return_handle = M.internal.wrap_shell_handle()
    opts.callback = function(data, complete)
        -- Short circuit in case we are killed while still processing
        if return_handle._stopped then return end
        -- Check to see if data has a handle attribute. If it does
        -- replace our existing handle reference with that one
        if data and data.handle then
            logger.debug("Received new handle reference from provider during async write. Updating our handle pointer")
            return_handle._handle = data.handle
            return
        end
        -- There is alot less bloat here as writes are pretty simple
        protected_callback(data, complete)
        return
    end
    local do_provider_write = function()
        if return_handle._stopped then
            logger.tracef("Write process for %s was stopped externally. Escaping write", uri)
            opts.callback(nil, true)
        end
        logger.tracef("Executing asynchronous write of data to %s with %s", uri, provider.name)
        local response = provider.write_a(uri, cache, lines, opts.callback)
        if not response then
            logger.errorf("Provider %s did not return anything for async write of %s... I hope you fall in an elderberry bush", provider.name, uri)
            return
        end
        if not response.handle then
            if response.success == false then
                local message = response.message or {
                    message = string.format("Provider %s reported failure while trying to write to %s", provider.name, uri)
                }
                logger.warn(string.format("Received failure while trying to write to %s with provider %s", uri, provider.name), message.message)
                opts.callback(message, true)
                return
            end
            logger.errorf("Provider %s did not return a handle on asynchronous write of %s. Disabling async write for this provider in the future...", provider.name, uri)
            provider.write_a = nil
            if not response.success then
                logger.warnf("Provider %s synchronously failed during async write of %s. Shit makes no sense to me...", provider.name, uri)
                opts.callback(response, true)
                return
            end
            opts.callback(true, true)
            return
        end
        return_handle._handle = response.handle
    end
    if not is_connected and provider.connect_host_a then
        logger.infof("Attempting provider %s connect to host of %s", provider.name, uri)
        local handle = provider.connect_host_a(
            uri,
            cache,
            function(success)
                if not success then
                    logger.warnf("Provider %s did not indicate success on connect to host of %s", provider.name, uri)
                end
                do_provider_write()
            end
        )
        if not handle then
            logger.warnf("Provider %s did not provide a proper async handle for asynchronous connection event. Removing async connect host", provider.name)
            provider.connect_host_a = nil
        end
        return_handle = M.internal.wrap_shell_handle(handle)
    else
        do_provider_write()
    end
    return return_handle
end

function M.internal._write_sync(uri, provider, cache, is_connected, lines)
    if not provider then
        logger.errorf("No provider provided for writing to %s", uri)
        return { success = false }
    end
    if not is_connected and provider.connect then
        logger.infof("Attempting provider %s connect to host of %s", provider.name)
        if not provider.connect(uri) then
            logger.warnf("Provider %s did not indicate success on connect to host of %s", provider.name, uri)
        end
    end
    logger.infof("Reaching out to %s to write to %s", provider.name, uri)
    local response = provider.write(uri, cache, lines)
    if not response.success then
        logger.warn(string.format("Provider %s indicated a failure while trying to write to %s", provider.name, uri), response)
    end
    return response
end

function M.write(buffer_index, uri, options, callback)
    options = options or {}
    local provider, cache, lines = nil, nil, {}
    uri, provider, cache = M.internal.validate_uri(uri)
    if not uri or not provider then
        return {
            success = false,
            message= {
                message = "Unable to find matching provider, or unable to validate uri!"
            }
        }
    end
    logger.infof("Reaching out to %s to write %s", provider.name, uri)
    if buffer_index then
        lines = vim.api.nvim_buf_get_lines(buffer_index, 0, -1, false)
        -- Consider making this an iterator instead
        for index, line in ipairs(lines) do
            if not line:match('[\n\r]$') then
                lines[index] = line .. '\n'
            end
        end
    end
    local is_connected = M.has_connection_to_uri_host(uri, provider, cache)
    if callback and provider.write_a then
        -- Asynchronous provider write
        logger.infof("Attempting asynchronous write to %s", uri)
        return M.internal._write_async(uri, provider, cache, is_connected, lines, callback)
    else
        logger.infof("Attempting synchronous write to %s", uri)
        return M.internal._write_sync(uri, provider, cache, is_connected, lines)
    end
end

--- Renames a URI to another URI, on the same provider
--- @param old_uri string
---     The current uri location to be renamed
--- @param new_uri string
---     The new uri name.
---     Note: Both URIs **MUST** share the same provider
--- @return table
---     Returns a table with the following information
---     {
---         success: boolean,
---         error: { message = "Error that occurred during rename "} -- (Optional)
---     }
function M.rename(old_uri, new_uri)
    local old_provider, new_provider, new_cache
    old_uri, old_provider = M.internal.validate_uri(old_uri)
    new_uri, new_provider, new_cache = M.internal.validate_uri(new_uri)
    if not old_provider or not new_provider then
        logger.warn("Unable to find matching providers to rename URIs!", {old_uri = old_uri, new_uri = new_uri})
        return {
            error = { message = "Unable to find matching providers for rename" },
            success = false
        }
    end
    if old_provider ~= new_provider then
        -- The URIs are not using the same provider!
        logger.warn("Invalid Provider Match found for rename of uris", {old_uri = old_uri, new_uri = new_uri, old_provider = old_provider, new_provider = new_provider})
        return {
            error = {
                message = string.format("Mismatched Providers for %s and %s", old_uri, new_uri)
            },
            success = false
        }
    end
    return new_provider.move(old_uri, new_uri, new_cache)
end

function M.internal.group_uris(uris)
    local grouped_uris = {}
    for _, uri in ipairs(uris) do
        local _, provider, cache = M.internal.validate_uri(uri)
        if not provider then
            -- TODO: Mike, I wonder if this should completely fail instead
            -- in the event that we don't find a matching provider for one of the provided
            -- uris?
            logger.warn(string.format("Unable to find matching provider for %s", uri))
            goto continue
        end
        if not grouped_uris[provider] then
            grouped_uris[provider] = { uris = {}, cache = cache }
        end
        table.insert(grouped_uris[provider].uris, uri)
        ::continue::
    end
    return grouped_uris
end

--- @see api.copy as this basically just does that (with the clean up option provided)
function M.move(uris, target_uri, opts)
    opts = opts or {}
    opts.cleanup = true
    return M.copy(uris, target_uri, opts)
end

--- @param uris table | string
---     The uris to copy. This can be a table of strings or a single string
--- @param target_uri string
---     The uri to copy the uris to
--- @param opts table | Optional
---     Default: {}
---     Any options for the copy function. Valid options 
---         - cleanup
---             - If provided, we will tell the originating provider to delete the origin uri after copy
---             has been completed
--- @return table
---     Returns a table with the following information
---     {
---         success: boolean,
---         error: { message = "Error that occurred during rename "} -- (Optional)
---     }
function M.copy(uris, target_uri, opts)
    opts = opts or {}
    if type(uris) == 'string' then uris = { uris } end
    local grouped_uris = M.internal.group_uris(uris)
    local _, target_provider, target_cache = M.internal.validate_uri(target_uri)
    if not target_provider then
        -- Something is very much not right
        local _error = string.format("Unable to find provider for %s", target_uri)
        logger.error(_error)
        return {
            error = { message = _error },
            success = false
        }
    end
    for provider, _ in pairs(grouped_uris) do
        if not provider.archive or not provider.archive.get then
            local _error = string.format("Provider %s did not implement archive.get", provider.name)
            logger.error(_error)
            return {
                error = { message = _error },
                success = false
            }
        end
    end
    if not target_provider.archive or not target_provider.archive.put then
        local _error = string.format("Target provider for %s did not implement archive.put", target_uri)
        logger.error(_error)
        return {
            error = { message = _error },
            success = false
        }
    end
    -- Attempting to perform the move/copy internally in the provider instead of archiving and pushing
    if grouped_uris[target_provider] then
        local command = 'copy'
        if opts.cleanup then
            command = 'move'
        end
        if not target_provider[command] then
            logger.warn(string.format("%s does nto support internal %s, attempting to force", target_provider.name, command))
            goto continue
        end
        local group = grouped_uris[target_provider]
        local target_uris = group.uris
        logger.info(string.format("Attempting to %s uris internally in provider %s", command, target_provider.name))
        local command_status = target_provider[command](target_uris, target_uri, target_cache)
        if command_status.success then
            -- The provider was able to interally move the URIs on it, removing them
            -- from the ones that need to be moved
            grouped_uris[target_provider] = nil
        end
        ::continue::
    end
    if not next(grouped_uris) then
        -- There is nothing left to do or there never was anything to do. Either way, we are done
        return {success = true}
    end
    local available_compression_schemes = target_provider.archive.schemes(target_uri, target_cache)
    if available_compression_schemes.error then
        -- Complain that we got an error from the target and bail
        local message = string.format("Received failure while looking for archive schemes for %s", target_uri)
        logger.warn(message, available_compression_schemes)
        return { error = available_compression_schemes.error, success = false }
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
            logger.warnn(message)
            logger.warn(message, archive_data.error)
            -- TODO: Consider a way to let the archival resume on failure if the user wishes...?
            return archive_data
        end
        local status = target_provider.archive.put(target_uri, target_cache, archive_data.archive_path, archive_data.scheme)
        if status.error then
            local message = string.format("Received error from %s while trying to upload archive", target_provider.name)
            logger.warnn(message)
            logger.warn(message, status)
        end
        if opts.cleanup then
            for _, uri in ipairs(data.uris) do
                status = provider.delete(uri, data.cache)
                if status.error then
                    local message = string.format("Received error during cleanup of %s", uri)
                    logger.warnn(message)
                    logger.warn(message, status)
                end
            end
        end
        -- -- Remove the temporary file
        assert(vim.loop.fs_unlink(archive_data.archive_path), string.format("Unable to remove %s", archive_data.archive))
    end
    return {success = true}
end

--- Attempts to submit a search to the provider of the URI.
--- NOTE: The provider may _not_ support searching, and thus
--- this might just return nil.
--- @param uri string
--- @param param string
--- @param opts table | Optional
---     Default: {
---         search = 'filename',
---         case_sensitive = false
---     }
---     If provided, alters both what we search, and how we search. This is (mostly) passed
---     directly to the provider.
---     Valid Key value pairs
---     - async: boolean
---         If provided, indicates to the provider that the search should be performed asynchronously
---     - output_callback: function
---         If provided, we will call this function with each item that is returned from the provider.
---         NOTE: If the provider does not support streaming of output, we will emulate it after the fact
---     - search: string
---         Valid values ('filename', 'contents')
---     - is_regex: boolean
---         If provided, indicates (to the provider) that the param is a regex
---     - case_sensitive: boolean
---         If provided, indicates (to the provider) that the param should (or should not) be case sensitive
---     - max_depth: integer
---         The maximium depth to perform the search
function M.search(uri, param, opts)
    local provider, cache = nil, nil
    uri, provider, cache = M.internal.validate_uri(uri)
    if not provider then
        logger.warn(string.format("Cannot find provider for %s", uri))
        return nil
    end
    if not provider.search then
        logger.info(string.format("%s does not support searching at this time", provider.name))
        return nil
    end
    opts = opts or { search = 'filename', case_sensitive = false}
    -- Validate that if we are doing this async, the return handle has the right info
    if opts.output_callback then
    end
    local data = provider.search(uri, cache, param, opts)
    return data
end

function M.delete(uri)
    local provider, cache = nil, nil
    uri, provider, cache = M.internal.validate_uri(uri)
    if not uri or not provider then return nil end
    logger.info(string.format("Reaching out to %s to delete %s", provider.name, uri))
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
    logger.tracef("Validating Metadata Request for %s", uri)
    local sanitized_metadata_keys = {}
    for _, key in ipairs(metadata_keys) do
        if not netman_options.explorer.METADATA[key] then
            logger.warn("Metadata Key: " ..
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
function M.unload_buffer(uri)
    local cached_file = M._providers.file_cache[uri]
    if vim.loop.fs_stat(cached_file) then
        compat.delete(cached_file)
    end
    M._providers.file_cache[uri]= nil
    local provider, cache = M.internal.get_provider_for_uri(uri)
    if provider.close_connection then
        provider.close_connection(uri, cache)
    end
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
    logger.info("Attempting to unload provider: " .. provider_path)
    local status, provider = pcall(require, provider_path)
    if not status or provider == true or provider == false then
        logger.warn("Failed to fetch provider " .. provider_path .. " for unload!")
        return
    end
    package.loaded[provider_path] = nil
    if provider.protocol_patterns then
        logger.info("Disassociating Protocol Patterns and Autocommands with provider: " .. provider_path)
        for _, pattern in ipairs(provider.protocol_patterns) do
            local _, _, new_pattern = pattern:find(protocol_pattern_sanitizer_glob)
            if M._providers.protocol_to_path[new_pattern] then
                logger.trace("Removing associated autocommands with " .. new_pattern .. " for provider " .. provider_path)
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
        logger.warn(string.format("%s is already loaded! Consider calling require('netman.api').reload_provider('%s') if you want to reload it"
            , provider_path, provider_path))
        return
    end
    local status, provider = pcall(require, provider_path)
    logger.info("Attempting to import provider: " .. provider_path)
    if not status or provider == true or provider == false then
        logger.info("Received following info on attempted import", { status = status, provider = provider })
        logger.errorn("Failed to initialize provider: " ..
            tostring(provider_path) ..
            ". This is likely due to it not being loaded into neovim correctly. Please ensure you have installed this plugin/provider")
        return
    end
    logger.info("Validating Provider: " .. provider_path)
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
    logger.info("Validation finished")
    if missing_attrs then
        logger.error("Failed to initialize provider: " ..
            provider_path .. ". Missing the following required attributes (" .. missing_attrs .. ")")
        M._providers.uninitialized[provider_path] = {
            reason = string.format("Validation Failure: Missing attribute(s) %s", missing_attrs)
            , name = provider_path
            , protocol = "Unknown"
            , version = "Unknown"
        }
        return
    end
    logger.trace("Initializing " .. provider_path .. ":" .. provider.version)
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
            logger.warn(string.format("%s:%s refused to initialize. Discarding", provider_path, provider.version), valid)
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
        logger.trace("Reducing " .. pattern .. " down to " .. new_pattern)
        local existing_provider_path = M._providers.protocol_to_path[new_pattern]
        if existing_provider_path then
            local existing_provider = M._providers.path_to_provider[existing_provider_path].provider
            if provider_path:find('^netman%.providers') then
                logger.trace(
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
            logger.info("Provider " .. existing_provider_path .. " is being overriden by " .. provider_path)
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
    logger.info("Initialized " .. provider_path .. " successfully!")
    ::exit::
end

function M.reload_provider(provider_path)
    M.unload_provider(provider_path)
    M.load_provider(provider_path)
end

--- Loads up the netman logger into a buffer.
--- @param output_path string | Optional
---     Default: $HOME/random_string.logger
---     If provided, this will be the file to write to. Note, this will write over whatever the file that is provided.
---     Note, you can provide "memory" to generate this as an in memory logger dump only
function M.generate_log(output_path)
    logger.tracef("Generating Session Log and dumping to %s", output_path)
    local neovim_details = vim.version()
    local host_details = vim.loop.os_uname()
    local headers = {
        '----------------------------------------------------',
        string.format("Neovim Version: %s.%s", neovim_details.major, neovim_details.minor),
        string.format("System: %s %s %s %s", host_details.sysname, host_details.release, host_details.version, host_details.machine),
        string.format("Netman Version: %s", M.version),
        "",
        ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>",
        "",
        "Running Provider Details"
    }
    for path, _ in pairs(M._providers.path_to_provider) do
        local provider = _.provider
        table.insert(headers, string.format("    %s --patterns %s --protocol %s --version %s", path, table.concat(provider.protocol_patterns, ','), provider.name, provider.version))
    end
    table.insert(headers, "")
    table.insert(headers, "Not Running Provider Details")
    for path, details in pairs(M._providers.uninitialized) do
        table.insert(headers, string.format("    %s --protocol %s --version %s --reason %s", path, details.protocol, details.version, details.reason))
    end
    table.insert(headers, ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>")
    table.insert(headers, '----------------------------------------------------')
    table.insert(headers, "Logs")
    table.insert(headers, "")
    local log_buffer = nil
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_option(buffer, 'filetype') ~= 'NetmanLogs' then
            goto continue
        else
            log_buffer = buffer
            break
        end
        ::continue::
    end
    if not log_buffer then
        log_buffer = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_buf_set_option(log_buffer, 'filetype', 'NetmanLogs')
    end

    vim.api.nvim_buf_set_option(log_buffer, 'modifiable', true)
    vim.api.nvim_set_current_buf(log_buffer)
    local pre_prepared_logs = require("netman.tools.utils.logger").get_session_logs(require("netman.tools.utils").session_id)
    for i = #headers, 1, -1 do
        local _log = headers[i]
        -- stuffing the headers into the pre_prepared_logs
        table.insert(pre_prepared_logs, 1, _log)
    end
    local logs = {}
    local handle = nil
    if output_path then
        local true_path = utils.get_real_path(output_path)
        if true_path then
            handle = io.open(true_path, 'w')
            logger.trace2f("Opening Handle to %s", output_path)
        else
            logger.warnnf("Unable to open %s to write to. Logs will be dropped into memory. You can save the buffer manually", output_path)
        end
    end
    for _, logline in ipairs(pre_prepared_logs) do
        for line in logline:gmatch('[^\r\n]+') do
            table.insert(logs, line)
            if handle then
                assert(handle:write(string.format('%s\n', line)), string.format("Unable to write log to %s", output_path))
            end
        end
    end
    if handle then
        logger.trace2f("Closing handle  for %s", output_path)
        assert(handle:flush(), string.format("Unable to save log file %s", output_path))
        assert(handle:close(), string.format("Unable to close log file %s", output_path))
    end
    vim.api.nvim_buf_set_lines(log_buffer, 0, -1, false, logs)
    vim.api.nvim_command('%s%\\n%\r%g')
    vim.api.nvim_command('%s%\\t%\t%g')
    vim.api.nvim_buf_set_option(log_buffer, 'modifiable', false)
    vim.api.nvim_buf_set_option(log_buffer, 'modified', false)
    vim.api.nvim_command('0')
end

-- @param event string
--     The event you wish to listen for.
-- @param callback function
--     The function you want me to call back.
--     When the event if fired, your function will be called, and provided a `data` param. The contents of the param will be
--         - event string
--             - The event that was fired
--         - source string
--             - The thing that triggered this event. May be nil, and will likely contain the name of the URI on things like
--                remote saves/reads/stat/exec, etc
-- @return integer
--     An integer ID that will be unique to your registered callback. Must be used to unregister. @see api.unregister_event_callback
-- @throw
--     INVALID_EVENT_ERROR
--        An error that is thrown if the requested event is not valid per `:h netman-events`s
--     INVALID_EVENT_CALLBACK_ERROR
--        An error that is thrown if there is no callback provided
-- @example
--     -- Dummy callback, use the data provided to it however you want
--     local callback = function(data) print(vim.inspect(data)) end
--     require("netman.api").register_event_callback("netman_provider_load", callback)
function M.register_event_callback(event, callback)
    assert(event, "INVALID_EVENT_ERROR: No event provided")
    assert(callback, "INVALID_EVENT_CALLBACK_ERROR: No callback provided")
    local id = rand_string(10)
    -- Ensuring we don't end up getting a duplicate id...
    while M.internal.events.handler_map[id] do id = rand_string(10) end
    local event_map = M.internal.events.event_map[event]
    if not event_map then
        event_map = {}
        M.internal.events.event_map[event] = event_map
    end
    table.insert(event_map, id)
    logger.debugf("Generated Event ID: %s for Event: %s", id, event)
    M.internal.events.handler_map[id] = callback
    return id
end

-- Unregisters the callback associated with the id
-- @param id integer
--     The id that was provided on the registration of the callback. @see netman.api.register_event_callback
-- @throw
--    INVALID_ID_ERROR
--      An error that is thrown if the id is nil
-- @example
--    local id = require("netman.api").register_event_callback('netman_provider_load', function(data) end)
--    require("netman.api").unregister_event_callback(id)
function M.unregister_event_callback(id)
    assert(id, "INVALID_ID_ERROR: No id provided")
    for event, e_map in pairs(M.internal.events.event_map) do
        for _, callback_id in ipairs(e_map) do
            if callback_id == id then
                logger.debugf("Removing ID: %s from Event: %s", id, event)
                table.remove(e_map, _)
            end
        end
    end
    M.internal.events.handler_map[id] = nil
end

-- Emits the event, and will also call any functions that might care about it
-- @param event string
--     A valid netman event
-- @param source string | Optional
--    Default: nil
--    If provided, this will be the URI source of the event.
-- @example
--     require("netman.api").emit_event("netman_provider_load")
function M.emit_event(event, source)
    local callbacks = M.internal.events.event_map[event]
    local message = string.format("Emitting Event: %s", event)
    if source then message = string.format("%s from %s", message , source) end
    logger.debug(message)
    if callbacks then
        logger.debugf("Found %s callbacks for event %s", #callbacks, event)
        for _, id in ipairs(callbacks) do
            -- TODO: Figure out how to make these calls asynchronously
            logger.tracef("Calling callback for %s for event %s", id, event)
            M.internal.events.handler_map[id]({event = event, source = source})
        end
    end
end

function M.init()
    if M._inited then
        logger.info("Netman API already initialized!")
        return
    end
    logger.info("--------------------Netman API initialization started!---------------------")
    logger.info("Creating Netman augroup")
    vim.api.nvim_create_augroup('Netman', {clear = true})
    M.internal.init_config()
    local core_providers = require("netman.providers")
    for _, provider in ipairs(core_providers) do
        M.load_provider(provider)
    end
    M._inited = true
    logger.info("--------------------Netman API initialization complete!--------------------")
end

M.init()
return M
