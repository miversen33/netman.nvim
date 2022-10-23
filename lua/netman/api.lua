-- TODO: (Mike): MOAR LOGS
local notify = require("netman.tools.utils").notify
local log = require("netman.tools.utils").log
local netman_options = require("netman.tools.options")
local cache_generator = require("netman.tools.cache")
local libruv = require('netman.tools.libruv')

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

--- The default function that any provider configuration will have associated with its 
--- :save function.
M.internal.config.save = function(self)
    local _config = io.open(require("netman.tools.utils").netman_config_path, 'w+')
    if not _config then
        error(string.format("Unable to write to netman configuration: %s", require("netman.tools.utils").netman_config_path))
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
    uninitialized    = {}
}

M._explorers = {}

local protocol_pattern_sanitizer_glob = '[%%^]?([%w-.]+)[:/]?'
local protocol_from_path_glob = '^([%w%-.]+)://'
local package_path_sanitizer_glob = '([%.%(%)%%%+%-%*%?%[%^%$]+)'
-- TODO(Mike): Potentially implement auto deprecation/enforcement here?
local _provider_required_attributes = {
    'name'
    ,'protocol_patterns'
    ,'version'
    ,'read'
    ,'write'
    ,'delete'
    ,'get_metadata'
}

--- WARN: Do not rely on these functions existing
--- WARN: Do not use these functions in your code
--- WARN: If you put an issue in saying anything about using
--- these functions is not working in your plugin, you will
--- be laughed at and ridiculed
function M.internal.init_config()
    local _lines = {}
    local _config = io.open(require("netman.tools.utils").netman_config_path, 'r')
    if not _config then
        error(string.format("Unable to read netman configuration file: %s", require("netman.tools.utils").netman_config_path))
    end
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

    log.trace(string.format("Loaded Configuration: %s", M.internal.config:serialize()))
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
    local is_shortcut = false
    local provider, cache, protocol = M.internal.get_provider_for_uri(uri)
    uri, is_shortcut = M.check_if_path_is_shortcut(uri)
    if not is_shortcut and not provider then
        log.warn(tostring(uri) .. " is not ours to deal with")
        return nil -- Nothing to do here, this isn't ours to handle
    elseif is_shortcut and not provider then
        log.trace("Searching for provider for " .. uri)
        provider, cache, protocol = M.internal.get_provider_for_uri(uri)
    end
    return uri, provider, cache, protocol
end

--- WARN: Do not rely on these functions existing
--- WARN: Do not use these functions in your code
--- WARN: If you put an issue in saying anything about using
--- these functions is not working in your plugin, you will
--- be laughed at and ridiculed
--- Generates a vim command that can be run, which will display the stream contents
--- @param read_data table
---     Array of lines
--- @param filetype string
---         Optional: Defaults to "detect"
---         If provided will set the filetype of the file to this.
--- @return string
---     vim command to run
function M.internal.read_as_stream(read_data, filetype)
    filetype = filetype or "detect"
    local command = "0append! " .. table.concat(read_data, '\n') .. " | set nomodified | filetype " .. filetype
    log.trace("Generated read stream command: " .. command:sub(1, 30))
    return command
end

--- WARN: Do not rely on these functions existing
--- WARN: Do not use these functions in your code
--- WARN: If you put an issue in saying anything about using
--- these functions is not working in your plugin, you will
--- be laughed at and ridiculed
--- Generates a vim command to load the pulled file into vim
--- @param read_data table
---     Table containing the following key value pairs
---     - origin_path
---         The path (local to the provider) that the file came from. Its origin
---     - local_path
---         The path (local to the filesystem) that the file lives on. Its local path
--- @param filetype string
---         Optional: Defaults to "detect"
---         If provided will set the filetype of the file to this.
--- @return string
---     vim command to run to load file into buffer
function M.internal.read_as_file(read_data, filetype)
    -- TODO: (Mike): Why do we have this? \/
    local origin_path = read_data.origin_path
    local local_path  = read_data.local_path
    filetype    = filetype or "detect"
    log.trace("Processing details: ", {origin_path=origin_path, local_path=local_path})
    local command = 'read ++edit ' .. local_path .. ' | set nomodified | filetype ' .. filetype
    log.trace("Generated read file command: " .. command)
    return command
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
function M.internal.read_as_explore(read_data)
    local sanitized_data = {}
    for _, data in pairs(read_data.remote_files) do
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

--- Initializes the Netman Augroups, what did you think it does?
function M.internal.init_augroups()
    local read_callback = function(callback_details)
        local uri, is_shortcut = M.check_if_path_is_shortcut(callback_details.match)
        log.debug("Read Details", {input_file=callback_details.match, uri=uri, is_shortcut=is_shortcut})
        if is_shortcut or M.internal.get_provider_for_uri(uri) then
                require("netman").read(uri)
            return
        else
            local command = 'edit'
            if callback_details.event == 'FileReadCmd' then
                command = 'read'
            end
            -- WARN: This may be an issue with opening files with swap already open...?
            pcall(vim.api.nvim_command, string.format('%s %s | filetype detect', command, uri))
        end
    end
    local write_callback = function(callback_details)
        local uri, is_shortcut = M.check_if_path_is_shortcut(callback_details.match)
        if is_shortcut or M.internal.get_provider_for_uri(uri) then
            require("netman").write(uri)
            return
        else
            return vim.api.nvim_command("w " .. uri)
        end
    end
    local buf_focus_callback = function(callback_details)
        if M.internal.get_provider_for_uri(callback_details.file) then
            log.trace("Setting Remote CWD To parent of " .. tostring(callback_details.file))
            libruv.change_buffer(callback_details.file)
        else
            libruv.clear_rcwd()
        end
    end
    local au_commands = {
       {'BufEnter', {
            group = 'Netman'
            ,pattern = '*'
            ,desc = 'Netman BufEnter Autocommand'
            ,callback = buf_focus_callback
            }
        }
        , {'FileReadCmd' , {
            group = "Netman"
            ,pattern = "*"
            ,desc = "Netman FileReadCmd Autocommand"
            ,callback = read_callback
            }
        }
        , {'BufReadCmd' , {
            group = "Netman"
            ,pattern = "*"
            ,desc = "Netman BufReadCmd Autocommand"
            ,callback = read_callback
            }
        }
        , {'FileWriteCmd', {
            group = "Netman"
            ,pattern = "*"
            ,desc = "Netman FileWriteCmd Autocommand"
            ,callback = write_callback
            }
        }
        , {'BufWriteCmd', {
            group = "Netman"
            ,pattern = "*"
            ,desc = "Netman BufWriteCmd Autocommand"
            ,callback = write_callback
            }
        }
        , {"BufUnload", {
            group = "Netman"
            ,pattern = "*"
            ,desc = "Netman BufUnload Autocommand"
            ,callback = function(callback_details) M.unload_buffer(callback_details.file, callback_details.buff) end
            }
        }
    }

    vim.api.nvim_create_augroup("Netman", {clear=true})
    for _, au_command in ipairs(au_commands) do
        log.info(string.format("Creating Auto Command %s|%s", au_command[1], au_command[2].desc))
        vim.api.nvim_create_autocmd(au_command[1], au_command[2])
    end
end

--- Reaches out to the provided provider and gets a list of
--- the entries it wants displayed
--- @param provider string
---    The string path of the provider in question. This should
---    likely be provided via netman.api.internal.get_providers()
--- @return table/nil
---    Returns a table with data or nil.
---    nil is returned if the provider is not valid or if the provider
---    doesn't have the `get_hosts` function implemented
---    NOTE: Does _not_ validate the schema, you do that yourself, whatever
---    is calling this
function M.internal.get_provider_entries(provider)
    local _provider = M._providers.path_to_provider[provider]
    local data = nil
    if not _provider then
        log.warn(string.format("%s is not a valid provider", provider))
        return data
    end
    _provider = _provider.provider
    if not _provider.get_hosts then
        log.info(string.format("%s has not implemented the get_hosts function", provider))
    else
        data = _provider.get_hosts()
    end
    return data
end

--- Returns a 1 dimensional table of strings which are registered
--- netman providers. Intended to be used with netman.api.get_provider_entries (but
--- I'm not the police, you do what you want with this).
--- @return table
function M.internal.get_providers()
    local _providers = {}
    for provider, _ in pairs(M._providers.path_to_provider) do
        table.insert(_providers, provider)
    end
    return _providers
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

--- Checks if the path is a URI that netman can manage
--- @param uri string
---     The uri to check
--- @return boolean
---     Returns true/false depending on if Netman can handle the uri
function M.is_path_netman_uri(uri)
    if M.internal.get_provider_for_uri(uri) then return true else return false end
end

--- Checks with the libruv to see if the provided path 
--- is a shortcut path to a uri
--- @param path string
---     The path to compare
--- @return string, boolean
---     Returns the real path if it exists, or it returns the original path
---     Returns True if the path was a shortcut and false if it isn't
function M.check_if_path_is_shortcut(path, direction)
    direction = direction or 'local_to_remote'
    if direction == 'local_to_remote' then
        return libruv.is_path_local_to_remote_map(path)
    elseif direction == 'remote_to_local' then
        return libruv.is_path_remote_to_local_map(path)
    else
        log.error('Unknown Shortcut Direction ' .. tostring(direction) .. ' for path ' .. path)
        error('Invalid Netman Path Shortcut Direction Check')
    end
end

--- Where Doc?
function M.read(uri)
    local provider, cache = nil, nil
    uri, provider, cache = M.internal.validate_uri(uri)
    if not uri or not provider then return nil end
    log.info(
        string.format("Reaching out to %s to read %s", provider.name, uri)
    )
    local read_data, read_type, parent_details = provider.read(uri, cache)
    if read_type == nil then
        log.info("Setting read type to api.READ_TYPE.STREAM")
        log.debug("back in my day we didn't have optional return values...")
        read_type = netman_options.api.READ_TYPE.STREAM
    end
    if netman_options.api.READ_TYPE[read_type] == nil then
        notify.error("Unable to figure out how to display: " .. uri .. '!')
        log.warn("Received invalid read type: " .. read_type .. ". This should be either api.READ_TYPE.STREAM or api.READ_TYPE.FILE!")
        return nil
    end
    if read_data == nil then
        log.info("Received nothing to display to the user, this seems wrong but I just do what I'm told...")
        return
    end
    if type(read_data) ~= 'table' then
        log.warn("Data returned is not in a table. Attempting to make it a table")
        log.debug("grumble grumble, kids these days not following spec...")
        read_data = {read_data}
    end
    -- TODO: (Mike): Validate the parent object is correct
    if read_type == netman_options.api.READ_TYPE.STREAM then
        log.info("Getting stream command for path: " .. uri)
        -- This should only happen if libruv is being used, otherwise
        -- its a useless call
        libruv.clear_rcwd()
        return M.internal.read_as_stream(read_data)
    elseif read_type == netman_options.api.READ_TYPE.FILE then
        log.info("Getting file read command for path: " .. uri)
        -- This should only happen if libruv is being used, otherwise
        -- its a useless call
        libruv.clear_rcwd()
        libruv.rcd(parent_details.local_parent, parent_details.remote_parent, uri)
        return M.internal.read_as_file(read_data)
    elseif read_type == netman_options.api.READ_TYPE.EXPLORE then
        log.info("Getting directory contents for path: " .. uri)
        return {
            contents = M.internal.read_as_explore(read_data),
            parent = {
                display = parent_details.local_parent,
                remote  = parent_details.remote_parent
            },
            current = {
                display = uri
            }
        }
    end
    log.warn("Mismatched read_type. How on earth did you end up here???")
    log.debug("Ya I don't know what you want me to do here chief...")
    return nil
end

function M.write(buffer_index, uri)
    local provider, cache = nil, nil
    uri, provider, cache = M.internal.validate_uri(uri)
    if not uri or not provider then return nil end
    log.info(string.format("Reaching out to %s to write %s", provider.name, uri))
    local lines = vim.api.nvim_buf_get_lines(buffer_index, 0, -1, false)
    for index, line in ipairs(lines) do
        if not line:match('[\n\r]$') then
            lines[index] = line .. '\n'
        end
    end
    -- TODO: Do this asynchronously
    provider.write(uri, cache, lines)
end

function M.delete(uri)
    local provider, cache = nil, nil
    uri, provider, cache = M.internal.validate_uri(uri)
    if not uri or not provider then return nil end
    log.info(string.format("Reaching out to %s to delete %s", provider.name,uri))
    -- Do this asynchronously
    provider.delete(uri, cache)
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
            log.warn("Metadata Key: " .. tostring(key) .. " is not valid. Please check `https://github.com/miversen33/netman.nvim/wiki/API-Documentation#get_metadatarequested_metadata` for details on how to properly request metadata")
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
function M.unload_buffer(uri, buffer_handle) end

--- Registers an explorer package which will be used to determine
--- what path to feed on cwd fetches
--- See netman.tools.options.explorer.EXPLORER_PACKAGES for predefined
--- packages that netman respects as explorers
--- @param explorer_package string
---     The name of the package to register
--- @return nil
function M.register_explorer_package(explorer_package)
    if not explorer_package then return end
    log.info(
        string.format("Registering %s an explorer package in netman!", explorer_package)
    )
    local sanitized_package = explorer_package:gsub(package_path_sanitizer_glob, '%%' .. '%1')
    M._explorers[explorer_package] = sanitized_package
end

--- Gets a list of all registered explorer packages with netman
--- See netman.api.register_explorer_packages for more details on how to
--- register a package
function M.get_explorer_packages()
    local explorers = {}
    for _, explorer in pairs(M._explorers) do
        table.insert(explorers, explorer)
    end
    return explorers
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
                        ,name = provider_path
                        ,protocol = table.concat(provider.protocol_patterns, ', ')
                        ,version = provider.version
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
        log.warn(provider_path .. " is already loaded! Consider calling require('netman.api').reload_provider('" .. provider_path .. "') if you want to reload this!")
        return
    end
    local status, provider = pcall(require, provider_path)
    log.info("Attempting to import provider: " .. provider_path)
    if not status or provider == true or provider == false then
        log.info("Received following info on attempted import", {status=status, provider=provider})
        notify.error("Failed to initialize provider: " .. tostring(provider_path) .. ". This is likely due to it not being loaded into neovim correctly. Please ensure you have installed this plugin/provider")
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
        log.error("Failed to initialize provider: " .. provider_path .. ". Missing the following required attributes (" .. missing_attrs .. ")")
        M._providers.uninitialized[provider_path] = {
            reason = string.format("Validation Failure: Missing attribute(s) %s", missing_attrs)
           ,name = provider_path
           ,protocol = "Unknown"
           ,version = "Unknown"
       }
        return
    end
    log.trace("Initializing " .. provider_path .. ":" .. provider.version)
    M._providers.path_to_provider[provider_path] = {provider=provider, cache=cache_generator:new(cache_generator.MINUTE)}
    if provider.init then
        log.trace("Found init function for provider!")
            -- TODO(Mike): Figure out how to load configuration options for providers
        local provider_config = M.internal.config:get(provider_path)
        if not provider_config then
            provider_config = require("netman.tools.configuration"):new()
            provider_config.save = function(_) M.internal.config:save() end
            M.internal.config:set(provider_path, provider_config)
        end
        provider_config:set('_last_loaded', vim.loop.now())
        M.internal.config:save()
        -- Consider having this being a timeout based async job?
        -- Bad actors will break the plugin altogether
        local valid = nil
        status, valid = pcall(
            provider.init
            ,provider_config
            ,M._providers.path_to_provider[provider_path].cache
        )
        if not status or valid ~= true then
            log.warn(provider_path .. ":" .. provider.version .. " refused to initialize. Discarding")
            M.unload_provider(provider_path, {
                 reason = "Initialization Failed"
                ,name = provider_path
                ,protocol = table.concat(provider.protocol_patterns, ', ')
                ,version = provider.version
            })
            return
        end
    end

    for _, pattern in ipairs(provider.protocol_patterns) do
        local _, _, new_pattern = pattern:find(protocol_pattern_sanitizer_glob)
        log.trace("Reducing " .. pattern .. " down to " .. new_pattern)
        local existing_provider_path  = M._providers.protocol_to_path[new_pattern]
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
                    ,name = provider_path
                    ,protocol = table.concat(provider.protocol_patterns, ', ')
                    ,version = provider.version
                }
                goto exit
            end
            log.info("Provider " .. existing_provider_path .. " is being overriden by " .. provider_path)
            M.unload_provider(existing_provider_path, {
                reason = "Overriden by " .. provider_path .. ":" .. provider.version
                ,name = existing_provider.name
                ,protocol = table.concat(existing_provider.protocol_patterns, ', ')
                ,version = existing_provider.version
            })
        end
        M._providers.protocol_to_path[new_pattern] = provider_path
    end
    M._providers.uninitialized[provider_path] = nil
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
    M.internal.init_augroups()
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
