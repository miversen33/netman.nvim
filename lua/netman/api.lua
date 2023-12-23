-- TODO: (Mike): MOAR LOGS
local utils = require("netman.tools.utils")
local netman_options = require("netman.tools.options")
local cache_generator = require("netman.tools.cache")
local logger = require("netman.tools.utils").get_system_logger()
local rand_string = require("netman.tools.utils").generate_string
local validator = require("netman.tools.utils.provider_validator").validate
local compat = require("netman.tools.compat")

local M = {}

-- WARN: Do not rely on these functions existing
-- WARN: Do not use these functions in your code
-- WARN: If you put an issue in saying anything about using
-- these functions is not working in your plugin, you will
-- be laughed at and ridiculed
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

-- Set of tools to communicate directly with provider(s) (in a generic sense).
-- Note, this will not let you talk directly to the provider per say, (meaning you can't
-- talk straight to the ssh provider, but you can talk to api and tell it you want things
-- from or to give to the ssh provider).
M.providers = {}

-- The default function that any provider configuration will have associated with its
-- :save function.
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

M.version = 1.02

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

-- WARN: Do not rely on these functions existing
-- WARN: Do not use these functions in your code
-- WARN: If you put an issue in saying anything about using
-- these functions is not working in your plugin, you will
-- be laughed at and ridiculed
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
        if return_handle._stopped or not return_handle._handle then return {} end
        return return_handle._handle.read(pipe)
    end

    function return_handle.write(data)
        if return_handle._stopped or not return_handle._handle then return end
        return return_handle._handle.write(data)
    end

    function return_handle.stop(force)
        if return_handle._stopped or not return_handle._handle then return end
        return_handle._stopped = true
        return return_handle._handle.stop(force)
    end

    return return_handle
end

-- WARN: Do not rely on these functions existing
-- WARN: Do not use these functions in your code
-- WARN: If you put an issue in saying anything about using
-- these functions is not working in your plugin, you will
-- be laughed at and ridiculed
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

-- WARN: Do not rely on these functions existing
-- WARN: Do not use these functions in your code
-- WARN: If you put an issue in saying anything about using
-- these functions is not working in your plugin, you will
-- be laughed at and ridiculed
-- Retrieves the provider and its cache for a protocol
-- @param protocol string
--     The protocol to check against
-- @return any, netman.tools.cache
--     Will return nil if we are unable to find a matching provider
function M.internal.get_provider_for_protocol(protocol)
    local provider_path = M._providers.protocol_to_path[protocol]
    if not provider_path then return nil end
    local provider_details = M._providers.path_to_provider[provider_path]
    return provider_details.provider, provider_details.cache
end

-- WARN: Do not rely on these functions existing
-- WARN: Do not use these functions in your code
-- WARN: If you put an issue in saying anything about using
-- these functions is not working in your plugin, you will
-- be laughed at and ridiculed
-- Retrieves the provider details for a URI
--@param uri string
-- The URI to extract the protocol (and thus the provider) from
--@return any, string/any, string/any
-- Returns the provider, its import path, and the protocol associated with the provider
--@private
function M.internal.get_provider_for_uri(uri)
    uri = uri or ''
    local protocol = uri:match(protocol_from_path_glob)
    local provider, cache = M.internal.get_provider_for_protocol(protocol)
    return provider, cache, protocol
end

-- WARN: Do not rely on these functions existing
-- WARN: Do not use these functions in your code
-- WARN: If you put an issue in saying anything about using
-- these functions is not working in your plugin, you will
-- be laughed at and ridiculed
-- @return uri, provider, cache, protocol
function M.internal.validate_uri(uri)
    local provider, cache, protocol = M.internal.get_provider_for_uri(uri)
    if not provider then
        logger.warn(string.format("%s is not ours to deal with", uri))
        return nil -- Nothing to do here, this isn't ours to handle
    end
    return uri, provider, cache, protocol
end

-- WARN: Do not rely on these functions existing
-- WARN: Do not use these functions in your code
-- WARN: If you put an issue in saying anything about using
-- these functions is not working in your plugin, you will
-- be laughed at and ridiculed
-- @param read_data table
--     A 1 dimensional table
-- @return table
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

-- Validates that the data provided in the `read` command for type `READ_FILE` is valid
-- @param table
--     Expects a table that contains the following keys
--     - remote_path  (Required)
--         - Value: String
--     - local_path   (Required)
--         - Value: String
--     - error        (Required if other fields are missing)
--         - TODO: Document this
--         - Value: Function
--         - Note: The expected return of the function is `{retry=bool}` where `bool` is either true/false. If `retry`
--         isn't present in the return of the error, or it if is and its false, we will assume that we shouldn't return
--         the read attempt
--     More details on the expected schema can be found in netman.tools.options.api.READ_RETURN_SCHEMA
-- @return table
--     Returns the validated table of information or (nil) if it cannot be validated
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

-- Initializes the Netman Augroups, what did you think it does?
function M.internal.init_augroups()
    vim.api.nvim_create_augroup('Netman', {clear = true})
end

-- Returns the associated config for the config owner.
-- @param config_owner_name string
--     The name of the owner of the config. Name should be the
--     path to the provider/consumer. Note, if there isn't one,
--     already available, **ONE IS NOT CREATED FOR YOU**
--     To get a config created for yourself, you should have registered
--     your provider with netman.api.load_provider. If you're a UI
--     you should be using netman.ui to get your config
-- @return Configuration
function M.internal.get_config(config_owner_name)
    return M.internal.config:get(config_owner_name)
end

-- Validates the information provided by the entry to ensure it
-- matches the defined schema in netman.tools.options.ui.ENTRY_SCHEMA.
-- If there are any invalid keys, they will be logged and stripped out.
-- @param entry table
--     A single entry returned by netman.api.get_hosts
-- @return table
--     A validated/sanitized entry
--     NOTE: If the entry is not validated, this returns nil
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

-- Returns a 1 dimensional table of strings which are registered
-- netman providers. Intended to be used with netman.api.providers.get_hosts (but
-- I'm not the police, you do what you want with this).
-- @return table
function M.providers.get_providers()
    local _providers = {}
    for provider, _ in pairs(M._providers.path_to_provider) do
        table.insert(_providers, provider)
    end
    return _providers
end

-- Reaches out to the provided provider and gets a list of
-- the entries it wants displayed
-- @param provider string
--    The string path of the provider in question. This should
--    likely be provided via netman.api.providers.get_providers()
-- @return table/nil
--    Returns a table with data or nil.
--    nil is returned if the provider is not valid or if the provider
--    doesn't have the `get_hosts` function implemented
--    NOTE: Does _not_ validate the schema, you do that yourself, whatever
--    is calling this
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

-- Gets details for a specific host
-- @param provider string
--     The path to the provider. For example, `netman.providers.ssh`. This will be provided by netman.api.provider.get_providers
-- @param host string
--     The name of the host. For example `localhost`. This will be provided by the provider via netman.api.providers.get_hosts
-- @return table
--     Returns a 1 dimensional table with the following information
--     - NAME (string)
--     - URI (string)
--     - STATE (string from netman.options.ui.states)
--     - ENTRYPOINT (table of URIs, or a function to call to get said table of URIs)
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

-- This will attempt to establish the connection with the provider
-- for the provided URI. If callback is provided, it will
-- be called after the connection event finishes.
-- @param provider table
--     The netman provider
-- @param uri string
--     The string URI to have the provider connect to
-- @param cache "netman.tools.cache"
--     The provider cache
-- @param callback function | nil
--     If provided, we will call this function (with no arguments) after
--     the connection event completes.
--     NOTE: Completion does not mean success or fail. Just done.
-- @return table | nil
--     If a callback is provided and we are able to get an async handle
--     on the connection event, we will return the handle. If no callback
--     is provided, or if we cannot asynchronously connect to the provider,
--     nothing is returned (but we will block until complete)
function M.internal.connect_provider(provider, uri, cache, callback)
    local is_connected = M.internal.has_connection_to_uri_host(uri, provider, cache)
    local do_async = callback and provider['connect_host_a'] and true or false
    local connection_func = do_async and 'connect_host_a' or 'connect_host'
    local connection_finished = false
    local handle = nil
    local connection_callback = function(success)
        -- We have already been handled, don't
        -- call again
        if connection_finished then return end
        if not success then
            logger.warnf("Provider %s did not indicate success on connect to host of %s", provider.name, uri)
        end
        connection_finished = true
        if callback then callback() end
    end
    if not is_connected then
        if not provider[connection_func] then
            logger.debugf("Provider %s does not seem to implement any sort of preconnection logic", provider.name)
            connection_callback(false)
            return
        end
        logger.debugf("Reaching out to `%s.%s` to attempt preconnection", provider.name, connection_func)
        handle = provider[connection_func](uri, cache, connection_callback)
        if do_async and not handle then
            logger.warnf("Provider %s did not provide a proper async handle for asynchronous connection event. Removing `%s`", provider.name, connection_func)
            provider.connect_host_a = nil
            connection_callback(false)
        end
    else
        connection_callback(true)
    end
    return handle
end

-- Attempts to reach out to the provider
-- to verify if the URI has a connected host
-- @param uri: string
--     The string URI to check
-- @param provider: table | nil
--     For internal use only, used to bypass uri validation
-- @param cache: table | nil
--     For internal use only, used to bypass uri validation
-- @return boolean
--     Will return True if (and only if) the provider
--     explicitly informed us that the URI was connected.
--     Failure to connect to the provider for this check,
--     or a false response from the provider will both return
--     false on this call
function M.internal.has_connection_to_uri_host(uri, provider, cache)
    local orig_uri = uri
    if not provider or not cache then
        uri, provider, cache = M.internal.validate_uri(uri)
    end
    if not uri or not provider then
        logger.warnf("Unable to find provider for %s, cannot verify connection status", orig_uri)
        return nil
    end
    if not provider.is_connected then
        logger.debugf("Provider %s does not report an `is_connected` function. Unable to verify connection status of %s", provider.name, uri)
        return false
    end
    logger.debugf("Reaching out to %s to verify connection status of %s", provider.name, uri)
    return provider.is_connected(uri, cache)
end

-- This might seem a bit convoluted if you don't understand what ASP is in netman.
-- This doc will not be used to go over that. Review `:h netman-asp` or go read the
-- readme on the repo for details.
-- @param provider table
--     The netman provider
-- @param sync_function_name string
--     The name of the synchronous version of the function to call
-- @param async_function_name string
--     The name of the asynchronous version of the function to call
-- @param data table
--     Table wrapped data to pass to the underlying async/sync function.
--     This table will be unpacked for the call
-- @param error_callback function | nil
--     The callback to call if there is any errors that occur during the processing
--     of the request
-- @param response_callback function | nil
--     So this one is a bit weird. This is the function to call when there is a 
--     response. Note, in order to properly perform the "ask" part of ASP, 
--     set this to `nil` if you wish to run synchronously only. Basically, 
--     just pass the consumer callback through to this. I know it seems weird. 
--
--     Just trust me bro.
-- @return table | nil
--     This function has no idea what it's returning. It is going to return 
--     (basically) whatever it gets back from the response callback, or the raw data
--     if no response function is returned. If the call passes ASP, it will 
--     return a proper netman async handle
--     Otherwise this will return nil
function M.internal.asp(provider, sync_function_name, async_function_name, data, error_callback, response_callback)
    local func = sync_function_name
    -- Checking to see if we even are supposed to run asynchronously
    -- Also checking if the async function exists. This is the ASK and SAY part of ASP
    local ask = response_callback and true or false
    logger.tracef("Performing ASP (ask) check on %s -> Was async requested? %s", provider.name, ask)
    local say = ask and provider[async_function_name] and true or false
    local prove = false
    if ask then
        logger.tracef("Performing ASP (say) check on %s -> Is `%s` available? %s", provider.name, async_function_name, say)
        func = say and async_function_name or func
    end
    logger.tracef(
        "Attempting to run `%s.%s` %s",
        provider.name,
        func,
        ask and say and "asynchronously" or "synchronously"
    )
    local status, response = pcall(provider[func], table.unpack(data))
    if not status then
        logger.errorf("`%s.%s` threw an error -> %s", provider.name, func, response)
    end
    prove = status == true and response and response.handle and true or false
    if ask and say then
        logger.tracef("Performing ASP (prove) check on `%s.%s` -> Was a proper async handle returned? %s", provider.name, func, prove)
        if not prove then
            logger.warnf("Provider %s did not return a proper async handle after async request. Removing %s from it for the remainder of this session", provider.name, func)
            -- Purposely using `async_function_name` as opposed to
            -- `func` to ensure that we don't accidentally remove the sync
            -- function
            provider[async_function_name] = nil
        end
        if not response then
            logger.warnf("`%s.%s` did not return anything useful. Calling fallback function `%s.%s`", provider.name, func, provider.name, sync_function_name)
            response = provider[sync_function_name](table.unpack(data))
        end
    end
    if not response then
        logger.errorf("Nothing was returned from call of `%s.%s`. Something bad likely happened, check out `:Nmlogs` for details", provider.name, func)
        local message = {
            message = "No response provided"
        }
        if error_callback then error_callback(message) end
        response = { success = false, message = message}
        return response
    end
    if response.handle then
        -- Short circuit the rest of the logic as this was successfully started
        -- as async
        logger.debugf("Received valid async handle from `%s.%s`, returning it now", provider.name, func)
        return response
    end
    if response_callback then
        logger.trace2("Passing result data to callback", response)
        response_callback(response, true)
        return
    end
    logger.trace("No response callback provided, returning data instead", response)
    return response
end

function M.internal._process_provider_response(uri, provider, response)
    if not response then
        logger.errorf("Provider `%s` did not return a valid response, crafting a jank one now", provider.name)
        return {
            success = false,
            message = {
                uri = uri
            }
        }
    end
    if not response.success then
        logger.infof("Provider `%s` failed to include success in response. Adding 'success=false' to response", provider.name)
        response.success = false
    end
    if not response.message and not response.data then
        logger.errorf("Provider `%s` didn't return anything useful! Response must include either a message attribute or a data attribute", provider.name)
        return {
            success = false,
            message = {
                uri = uri
            }
        }
    end
    if response.message then
        if not response.message.uri then
            logger.infof("Provider `%s` didn't include the uri in its message. Adding it now", provider.name)
            response.message.uri = uri
        end
        if response.message.error then
            logger.tracef("Validating provided error %s", response.message.error)
            if not netman_options.api.ERRORS[response.message.error] then
                logger.warnf("Provider `%s` returned an invalid error \"%s\". Stripping it out now. Errors must comply with \"netman.tools.options.api.ERRORS\"", provider.name, response.message.error)
                response.message.error = nil
            end
        end
    end
    return response
end

-- WARN: Do not rely on these functions existing
-- WARN: Do not use these functions in your code
-- WARN: If you put an issue in saying anything about using
-- these functions is not working in your plugin, you will
-- be laughed at and ridiculed
function M.internal._process_read_result(uri, provider, data)
    local provider_name = provider.name or 'nil'
    local processed_data = nil
    local validated_response = M.internal._process_provider_response(uri, provider, data)
    if not validated_response.success then
        logger.warn(string.format("There was a potential failure in reading %s", uri), validated_response)
        return validated_response
    end
    if not netman_options.api.READ_TYPE[validated_response.type] then
        logger.warnf("Unable to trust data type %s. Sent from provider %s while trying to read %s", validated_response.type or 'nil', provider_name, uri)
        return validated_response
    end
    if not validated_response.data then
        return validated_response
    end
    if validated_response.type == netman_options.api.READ_TYPE.EXPLORE then
        processed_data = M.internal.sanitize_explore_data(validated_response.data)
    elseif validated_response.type == netman_options.api.READ_TYPE.FILE then
        processed_data = M.internal.sanitize_file_data(validated_response.data)
        if not processed_data then
            logger.warn(string.format("Provider %s did not return valid return data for %s", provider_name, uri), { data = validated_response.data })
            return nil
        end
        if not processed_data.error and processed_data.local_path then
            logger.tracef("Caching %s to local file %s", uri, processed_data.local_path)
            M._providers.file_cache[uri] = processed_data.local_path
        end
    else
        processed_data = validated_response.data
    end
    return { data = processed_data , type = validated_response.type, success = validated_response.success }
end

-- Executes remote read of uri
-- NOTE: Read also caches results for a short time, and will
-- return those cached results instead of repeatedly reaching
-- out to the underlying provider for repeat requests.
-- @param uri string
--     The string representation of the remote resource URI
-- @param opts table | nil
--     Default: {}
--     Options to provide to the provider. Valid options include
--     - force: boolean
--         If provided, indicates that we should invalidate any cached
--         instances of the URI before pull
-- @param callback function | nil
--     Default: nil
--     If provided, we will attempt to treate the read request as asynchronous.
--     NOTE: this affects the return value!
-- @return table
--     If the read request is asynchronous, you will recieve the following table
--     {
--         async: boolean,
--         -- A boolean that should be set to true to indicate that
--         -- the read request is asynchronously being completed
--         read: function,
--         -- Takes an optional string parameter that can be
--         -- "STDERR", or "STDOUT" to indicate which pipe to read from.
--         -- Defaults to "STDOUT"
--         write: function,
--         -- Takes a string or table of data to write to the
--         -- underlying handle
--         stop: function
--         -- Takes an optional boolean to indicate the stop should
--         -- be forced
--     }
--     Note, the synchronous output below will be provided to the callback param
--     as a parameter to it instead, with the exception of the following keys
--     - async, success
--     Its pretty obvious that the results are async as they are being streamed to
--     you, and success is also obvious if you are receiving the output
--     
--     If the read request is synchronous, you will receive the following table
--     {
--         async: boolean,
--         -- A boolean that should be set to false to indicate that
--         -- the read request was synchronously completed
--         success: boolean,
--         -- A boolean indicating if the read was successfully completed
--         type: string,
--         -- A string indicating what type of result you will receive. Valid
--         -- types are
--         -- - "EXPLORE"
--         --     -- Indicates a directory style set of data. This
--         --     -- means the `data` key will be a 1 dimensional array
--         --     -- containing a stat table for each item returned
--         -- - "FILE"
--         --     -- Indicates an individual file type of data. This
--         --     -- means that there is a file located somewhere on the host
--         --     -- machine that is the result of whatever was pulled down
--         --     -- from the URI. `data` will be formatted in the following manner
--         --     -- {
--         --            local_path: string,
--         --                -- The local path to the downloaded file
--         --            origin_path: string,
--         --                -- The remote path that was read for this file
--         --     -- }
--         -- - "STREAM"
--         --     -- Indicates a stream of data. This means that there
--         --     -- is no data stored locally and and such `data` will be
--         --     -- a 1 dimensional array of "lines" of output
--         data: table,
--         -- See `type` for details on how this table will be formatted,
--         -- based on the type of data returned by the provider
--         message: table | nil,
--         -- An optional table that may be returned by the provider.
--         -- If this table exists, it will be in the following format
--         -- {
--         --     message: string,
--         --     -- The message to relay to the consumer
--         --     process: function | nil,
--         --     -- If provided, indicates that the provider expects
--         --     -- the message to be an input prompt of some kind.
--         --     -- Call process with the result of the prompt so the
--         --     -- provider can continue with whatever it was doing.
--         --     -- NOTE: This will return a table with the following info
--         --     -- {
--         --     --     retry: boolean,
--         --     --     -- Indicates if you should recall the original function
--         --     --     -- call again. IE, if true, call api.read again
--         --     --     -- with the original params
--         --     --     message: string | nil
--         --     --     -- The message printed during the retry. Usually
--         --     --     -- this indicates a complete failure of the call and
--         --     --     -- retry logic altogether
--         --     -- }
--         --     default: string | nil,
--         --     -- If provided, indicates the default value to put
--         --     -- in for whatever the prompt is that was provided with
--         --     -- the message key
--         -- }
--     }
function M.read(uri, opts, callback)
    local orig_uri = uri
    local provider, cache = nil, nil
    uri, provider, cache, _ = M.internal.validate_uri(uri)
    if not uri or not provider then
        return {
            success = false,
            message = {
                message = string.format("Unable to read %s or unable to find provider for it", orig_uri)
            }
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
    local return_handle = M.internal.wrap_shell_handle()
    local return_data = nil
    local protected_callback = function(data, complete)
        if not callback then return end
        -- There is nothing to do, leave us alone
        if data == nil and complete == nil then return end
        local success, _error = pcall(callback, data, complete)
        if not success then
            logger.warn("Read return processing experienced a failure!", _error)
        end
    end
    local result_callback = function(data, complete)
        -- Short circuit in case we are killed while still processing
        -- If this is a sync call (either by the consumer or ASP failure)
        -- it is impossible for this to be set to true
        if return_handle._stopped == true then return end
        if data and data.handle then
            logger.debug("Received new handle reference from provider durin read. Updating our handle pointer")
            return_handle._handle = data.handle
            return
        end
        if complete and not data then
            logger.errorf("%s did not return valid data on completion of read of %s", provider.name, uri)
            -- There is nothing of substance passed,
            -- but the complete flag was still provided.
            -- Call the consumer's complete handle and return
            protected_callback(nil, complete)
            return
        end
        return_data = M.internal._process_read_result(uri, provider, data)
        protected_callback(return_data, complete)
    end
    local error_callback = function(err)
        logger.warn(err)
    end
    local connection_callback = function()
        local raw_handle = M.internal.asp(
            provider,
            'read',
            'read_a',
            {uri, cache, result_callback},
            error_callback,
            callback and result_callback
        )
        if raw_handle then
            if raw_handle.handle then
                return_handle._handle = raw_handle
            elseif not callback then
                result_callback(raw_handle)
            end
        end
    end
    return_handle._handle = M.internal.connect_provider(
        provider,
        uri,
        cache,
        connection_callback
    )
    if callback then
        return return_handle
    else
        return return_data
    end
end

function M.write(uri, data, options, callback)
    data = data or {}
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
    -- Deprecated, we should instead require the data to be passed in as content only
    if data.type == 'buffer' then
        lines = vim.api.nvim_buf_get_lines(data.index, 0, -1, false)
        -- Consider making this an iterator instead
        for index, line in ipairs(lines) do
            if not line:match('[\n\r]$') then
                lines[index] = line .. '\n'
            end
        end
    elseif data.type == 'content' then
        lines = data.data
    end
    -- TODO: Add support for data.file to upload local files
    local return_handle = M.internal.wrap_shell_handle()
    local return_data = nil
    local protected_callback = function(_data, complete)
        if not callback then return end
        -- There is nothing to process, leave us alone
        if _data == nil and complete == nil then return end
        local success, _error = pcall(callback, _data, complete)
        if not success then
            logger.warn("Write return processing experienced a failure!", _error)
        end
    end
    local result_callback = function(_data, complete)
        -- Short circuit in case we are killed while still processing
        -- If this is a sync call (either by the consumer or ASP failure)
        -- it is impossible for this to be set to true
        if return_handle._stopped == true then return end
        if _data and _data.handle then
            logger.debug("Received new handle reference from provider during async write. Updating our handle pointer")
            return_handle._handle = _data.handle
            return
        end
        if _data and _data.message then
            logger.debugf("Logging message provided by %s for consumer: %s", provider, _data.message)
        end
        return_data = _data
        protected_callback(return_data, complete)
    end
    local error_callback = function(err)
        logger.warn(err)
    end
    local connection_callback = function()
        local raw_handle = M.internal.asp(
            provider,
            "write",
            "write_a",
            {uri, cache, lines, result_callback},
            error_callback,
            result_callback
        )
        if raw_handle then
            if raw_handle.handle then
                return_handle._handle = raw_handle
            elseif not callback then
                result_callback(raw_handle)
            end
        end
    end
    return_handle._handle = M.internal.connect_provider(provider, uri, cache, connection_callback)
    if callback then
        return return_handle
    else
        return return_data
    end
end

-- Renames a URI to another URI, on the same provider
-- @param old_uri string
--     The current uri location to be renamed
-- @param new_uri string
--     The new uri name.
--     Note: Both URIs **MUST** share the same provider
-- @return table
--     Returns a table with the following information
--     {
--         success: boolean,
--         message: { message = "Error that occurred during rename "} -- (Optional)
--     }
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

-- Literally just returns whatever @see copy does, but tells copy to do a move instead
function M.move(uris, target_uri, opts, callback)
    return M.copy(uris, target_uri, opts, callback, true)
end

-- Attempts to perform an intra-provider copy/move of uri(s) to a target uri.
-- 
-- Note: This does _not_ allow **inter**-provider copy/move and any attempt to do so
-- will result in an error.
--
-- Note: This does _not_ provide "same host" checking, that is something that the provider
-- is expected to handle if it cares about that. This means that
-- as a provider, you may receive a request to copy/move data from one host to another.
-- 
-- @param uris table | string
--     The uris to copy. This can be a table of strings or a single string
-- @param target_uri string
--     The uri to copy the uris to
-- @param opts table | nil
--     Default: {}
--     Any options for the copy function. Valid options 
--         - cleanup
--             - If provided, we will tell the originating provider to delete the origin uri after copy
--             has been completed
-- @return table
--     Returns a table with the following information
--     ```lua
--     {
--         success: boolean,
--         message: { message = "Error that occurred during rename "} -- (Optional)
--     }
--     ```
function M.copy(uris, target_uri, opts, callback, do_move)
    opts = opts or {}
    local command = do_move and 'move' or 'copy'
    local target_provider, target_cache = nil, nil
    target_uri, target_provider, target_cache = M.internal.validate_uri(target_uri)
    if not target_uri or not target_provider then
        return {
            success = false,
            message = {
                message = string.format("Unable to %s to %s or unable to find provider for it", command, target_uri)
            }
        }
    end
    for _, uri in ipairs(uris) do
        local provider = nil
        uri, provider = M.internal.validate_uri(uri)
        if not uri or not provider or provider ~= target_provider then
            return {
                success = false,
                message = {
                    message = string.format("Unable to %s from %s as it has a different provider than target %s", command, uri, target_uri)
                }
            }
        end
    end
    logger.info(
        string.format("Reaching out to %s to %s [%s] to %s",
            target_provider.name,
            command,
            table.concat(uris, ", "),
            target_uri
        )
    )
    local return_handle = M.internal.wrap_shell_handle()
    local return_data = nil

    local protected_callback = function(data, complete)
        if not callback then return end
        if data == nil or complete == nil then return end
        local success, _error = pcall(callback, data, complete)
        if not success then
            logger.warn(string.format("%s return processing experienced a failure!", command), _error)
        end
    end
    local result_callback = function(data, complete)
        if return_handle._stopped == true then return end
        -- TODO: Support streaming updates of command?
        if data and data.handle then
            logger.debug(
                string.format("Received a new handle reference from provider during async %s. Updating our handle pointer", command)
            )
            return_handle._handle = data.handle
            return
        end
        if data and data.message then
            logger.debugf("Logging message provided by %s for consumer: %s", target_provider.name, data.message)
        end
        return_data = data
        protected_callback(return_data, complete)
    end
    local error_callback = function(err)
        logger.warn(err)
    end
    local connection_callback = function()
        local raw_handle = M.internal.asp(
            target_provider,
            command,
            string.format("%s_a", command),
            {
                uris, target_uri, target_cache, result_callback
            },
            error_callback,
            callback and result_callback
        )
        if raw_handle then
            if raw_handle.handle then
                return_handle._handle = raw_handle
            elseif not callback then
                result_callback(raw_handle)
            end
        end
    end
    return_handle._handle = M.internal.connect_provider(
        target_provider,
        target_uri,
        target_cache,
        connection_callback
    )

    if callback then
       return return_handle
    else
        return return_data
    end
end

--- Attempts to submit a search to the provider of the URI.
--- NOTE: The provider may _not_ support searching, and thus
--- this might just return nil.
--- @param uri string
--- @param param string
--- @param opts table | nil
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

function M.delete(uri, callback)
    local orig_uri = uri
    local provider, cache = nil, nil
    uri, provider, cache, _ = M.internal.validate_uri(uri)
    if not uri or not provider then
        return {
            success = false,
            message = string.format("Unable to get metadata for %s or unable to find provider for it", orig_uri)
        }
    end
    -- Even if we are unsuccessful, we should at least delete the local
    -- cached version
    M._providers.file_cache[uri] = nil
    local return_handle = M.internal.wrap_shell_handle()
    local return_data = nil
    local protected_callback = function(data, complete)
        if not callback then return end
        if data == nil and complete == nil then return end
        local success, _error = pcall(callback, data, complete)
        if not success then
            logger.warn("Delete return processing experienced a failure!", _error)
        end
    end
    local result_callback = function(data, complete)
        if return_handle._stopped == true then return end
        if data and data.handle then
            logger.debug("Received new handle reference from provider during async delete. Updating our handle pointer")
            return_handle._handle = data.handle
            return
        end
        if data and data.message then
            logger.debugf("Logging message provided by %s for consumer: %s", provider, data.message)
        end
        return_data = data
        protected_callback(data, complete)
    end
    local error_callback = function(err)
        logger.warn(err)
    end
    local connection_callback = function()
        local raw_handle = M.internal.asp(
            provider,
            'delete',
            'delete_a',
            {uri, cache, result_callback},
            error_callback,
            result_callback
        )
        if raw_handle then
            if raw_handle.handle then
                return_handle._handle = raw_handle
            elseif not callback then
                result_callback(raw_handle)
            end
        end
        protected_callback(return_data)
    end
    return_handle._handle = M.internal.connect_provider(provider, uri, cache, connection_callback)
    if callback then
        return return_handle
    else
        return return_data
    end
end

function M.get_metadata(uri, metadata_keys, options, callback)
    options = options or {}
    local orig_uri = uri
    metadata_keys = metadata_keys or {}
    local provider, cache = nil, nil
    uri, provider, cache, _ = M.internal.validate_uri(uri)
    if not uri or not provider then
        return {
            success = false,
            message = string.format("Unable to get metadata for %s or unable to find provider for it", orig_uri)
        }
    end
    if #metadata_keys == 0 then
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
    local return_handle = M.internal.wrap_shell_handle()
    local return_data = nil
    local protected_callback = function(data, complete)
        if not callback then return end
        if data == nil and complete == nil then return end
        local success, _error = pcall(callback, data, complete)
        if not success then
            logger.warn("Get Metadata return processing experienced a failure!", _error)
        end
    end
    local result_callback = function(data, complete)
        if return_handle._stopped == true then return end
        if data and data.handle then
            logger.debug("Received new handle reference from provider during async get_metadata. Updating our handle pointer")
            return_handle._handle = data.handle
            return
        end
        if data and data.message then
            logger.debugf("Logging message provided by %s for consumer: %s", provider, data.message)
        end
        local metadata = {}
        for _, key in ipairs(metadata_keys) do
            if data and data.data and data.data[key] then
                metadata[key] = data.data[key]
            end
        end
        return_data = metadata
        protected_callback({success = true, data = return_data}, complete)
    end
    local error_callback = function(err)
        logger.warn(err)
    end
    local connection_callback = function()
        local raw_handle = M.internal.asp(
            provider,
            'get_metadata',
            'get_metadata_a',
            {uri, cache, metadata_keys, result_callback},
            error_callback,
            callback and result_callback
        )
        if raw_handle then
            if raw_handle.handle then
                return_handle._handle = raw_handle
            elseif not callback then
                result_callback(raw_handle)
            end
        end
    end
    return_handle._handle = M.internal.connect_provider(provider, uri, cache, connection_callback)
    if callback then
        return return_handle
    else
        return return_data
    end

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

-- Unload Provider is a function that is provided to allow a user (developer)
-- to remove a provider from Netman. This is most useful when changes have been
-- made to the provider and you wish to reflect those changes without
-- restarting Neovim
-- @param provider_path string
--    The string path to the provider
--    EG: "netman.provider.ssh"
-- @return nil
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

-- Load Provider is what a provider should call
-- (via require('netman.api').load_provider) to load yourself
-- into netman and be utilized for uri resolution in other
-- netman functions.
-- @param provider_path string
--    The string path to the provider
--    EG: "netman.provider.ssh"
-- @return nil
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
    local validation_details = validator(provider)
    logger.trace("Validated Provider -> ", validation_details.provider)
    local missing_attrs = table.concat(validation_details.missing_attrs, ', ')
    logger.info("Validation finished")
    if #validation_details.missing_attrs > 0 then
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
    provider = validation_details.provider
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

    local valid_protocols = {}
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
        table.insert(valid_protocols, new_pattern)
        M._providers.protocol_to_path[new_pattern] = provider_path
    end
    -- Adding a new attribute to track the protocols that a provider can handle
    provider.protocols = valid_protocols
    -- Adding a new attribute to track the provider's path
    provider.path = provider_path
    M._providers.uninitialized[provider_path] = nil
    M.internal.init_provider_autocmds(provider, provider.protocol_patterns)
    logger.info("Initialized " .. provider_path .. " successfully!")
    ::exit::
end

function M.reload_provider(provider_path)
    M.unload_provider(provider_path)
    M.load_provider(provider_path)
end

-- Loads up the netman logger into a buffer.
-- @param output_path string | nil
--     Default: $HOME/random_string.logger
--     If provided, this will be the file to write to. Note, this will write over whatever the file that is provided.
--     Note, you can provide "memory" to generate this as an in memory logger dump only
function M.generate_log(output_path)
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
    local do_tail = true
    local scroll_to_threshold = 10
    local handle_cursor_move_event = function()
        local buffer_window_id = nil
        for _, win_id in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win_id) == log_buffer then
                buffer_window_id = win_id
                break
            end
        end
        if not buffer_window_id then return end
        local cursor_position = vim.api.nvim_win_get_cursor(buffer_window_id)
        if math.abs(cursor_position[1] - vim.api.nvim_buf_line_count(log_buffer)) <= scroll_to_threshold then
            do_tail = true
        else
            do_tail = false
        end
    end
    local nmlogs_forwarder = function(logline)
        local new_logs = {}
        for line in logline:gmatch('[^\r\n]+') do
            table.insert(new_logs, line)
        end
        vim.api.nvim_buf_set_option(log_buffer, 'modifiable', true)
        vim.api.nvim_buf_set_lines(log_buffer, -1, -1, false, new_logs)
        vim.api.nvim_buf_set_option(log_buffer, 'modifiable', false)
        vim.api.nvim_buf_set_option(log_buffer, 'modified', false)
        if not do_tail then return end
        for _, win_id in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win_id) == log_buffer then
                vim.api.nvim_win_set_cursor(win_id, {vim.api.nvim_buf_line_count(log_buffer), 0})
                break
            end
        end
    end
    local nmlogs_forwarder_id = require("netman.tools.utils.logger").add_log_forwarder(nmlogs_forwarder)
    vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = log_buffer,
        desc = "Netman Nmlogs autocommand to catch cursor move and stop auto tail",
        callback = handle_cursor_move_event
    })
    vim.api.nvim_create_autocmd('CursorMovedI', {
        buffer = log_buffer,
        desc = "Netman Nmlogs autocommand to catch cursor move and stop auto tail",
        callback = handle_cursor_move_event
    })
    vim.api.nvim_create_autocmd('BufDelete', {
        buffer = log_buffer,
        desc = "Netman Nmlogs autocommand to disable all the cruft when its log buffer is closed",
        callback = function()
            require("netman.tools.utils.logger").remove_log_forwarder(nmlogs_forwarder_id)
        end
    })
    vim.api.nvim_buf_set_lines(log_buffer, 0, -1, false, logs)
    vim.api.nvim_command('%s%\\n%\r%g')
    vim.api.nvim_command('%s%\\t%\t%g')
    vim.api.nvim_buf_set_option(log_buffer, 'modifiable', false)
    vim.api.nvim_buf_set_option(log_buffer, 'modified', false)
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
-- @param source string | nil
--    Default: nil
--    If provided, this will be the URI source of the event.
-- @example
--     require("netman.api").emit_event("netman_provider_load")
function M.emit_event(event, source)
    local callbacks = M.internal.events.event_map[event]
    local message = string.format("Emitting Event: %s", event)
    if source then message = string.format("%s from %s", message , source) end
    logger.trace2(message)
    if callbacks then
        logger.tracef("Found %s callbacks for event %s", #callbacks, event)
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
