--- Notes
--- We need to document not just how this works internally
--- but _also_ what events this catches
--- what autocommands we rely on
--- what autocommands we fire off
--- what we interact with
--- Basically everything

local utils = require('netman.utils')
local netman_options = require('netman.options')
local log = utils.log
local notify = utils.notify

local protocol_pattern_sanitizer_glob = '[%%^]?([%w-.]+)[:/]?'
local protocol_from_path_glob = '^([%w%-.]+)://'

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

local _explorer_required_attributes = {
    'version'
    ,'protocol_patterns'
    ,'explore'
}

local M = {}

M.version = 1.0
M.explorer = nil
M._augroup_defined = false
M._initialized = false
M._setup_commands = false
M._buffer_provider_cache = {
    -- Tables that are added to this table should contain the following
    -- key,value pairs
    -- key: Buffer Index (as string)
    -- value: Table with the following key, value pairs
    --     key: protocol
    --     value: Table with the following key, value pairs
    --         provider: required provider from pcall
    --         origin_path: original uri used to create this connection
    --         protocol: set this to your global (required) name value
    --         buffer: set this to nil, it will be set later
    --         provider_cache: empty table object
}
M._providers = {
    -- Contains key, value pairs as follows
    -- key: Protocol (pre glob)
    -- value: imported provider
}
M._unitialized_providers = {
    -- Contains key, value pairs as follows
    -- key: provider name
    -- value: reason it is unitilized
}
M._unintialized_explorers = {
    -- Contains key, value pairs as follows
    -- key: explorer name
    -- value: reason it is unitilized
}
M._unclaimed_provider_details = {

}

M._unclaimed_id_table = {

}

local _get_provider_for_path = function(path)
    local provider = nil
    local protocol = path:match(protocol_from_path_glob)
    provider = M._providers[protocol]
    if provider == nil then
        notify.error("Error parsing path: " .. path .. " -- Unable to establish provider")
        return nil, nil
    end
    log.info("Selecting provider: " .. provider._provider_path .. ':' .. provider.version .. ' for path: ' .. path)
    return provider, protocol
end

local _read_as_stream = function(stream)
    -- TODO(Mike): Allow for providing the file type
    local command = "0append! " .. table.concat(stream, '\n')
    log.debug("Generated read stream command: " .. command:sub(1, 30))
    return command
end

local _read_as_file = function(file)
    -- TODO(Mike): Allow for providing the file type
    local origin_path = file.origin_path
    local local_path  = file.local_path
    local unclaimed_id = M._unclaimed_id_table[origin_path]
    local claim_command = ''
    if unclaimed_id then
        claim_command = ' | lua require("netman.api"):_claim_buf_details(vim.fn.bufnr(), "' .. M._unclaimed_id_table[origin_path] .. '")'
    end
    log.debug("Processing details: ", {origin_path=origin_path, local_path=local_path, unclaimed_id=unclaimed_id})
    local command = 'read ++edit ' .. local_path .. ' | set nomodified | filetype detect' .. claim_command
    log.debug("Generated read file command: " .. command)
    return command
end

local _read_as_explore = function(explore_details)
    local sanitized_explore_details = {}
    for _, details in ipairs(explore_details.remote_files) do
        for _, field in ipairs(netman_options.explorer.FIELDS) do
            if details[field] == nil then
                log.warn("Explore Details Missing Required Field: " .. field)
            end
        end
        for key, _ in ipairs(details) do
            if  netman_options.explorer.FIELDS[key] == nil
            and netman_options.explorer.METADATA[key] == nil then
                log.info("Stripping out " .. key .. " from explore details as it does not conform with netman.options.explorer.FIELDS or netman.options.explorer.METADATA")
                details[key] = nil
            end
        end
        table.insert(sanitized_explore_details, details)
    end
    return {
        parent=explore_details.parent,
        details=sanitized_explore_details
    }
end

local _cache_provider = function(provider, protocol, path)
    if M._unclaimed_id_table[path] then
        return M._unclaimed_id_table[path], M._unclaimed_provider_details[M._unclaimed_id_table[path]]
    end
    log.debug("Reaching out to provider: " .. provider._provider_path .. ":" .. provider.version .. " to initialize connection for path: " .. path)
    local id = utils.generate_string(10)
    local bp_cache_object = {
        provider        = provider
        ,protocol       = protocol
        ,local_path     = nil
        ,origin_path    = path
        ,unique_name    = ''
        ,buffer         = nil
        ,provider_cache = {}
    }
    M._unclaimed_provider_details[id] = bp_cache_object
    M._unclaimed_id_table[path] = id
    log.debug("Cached provider: " .. provider._provider_path .. ":" .. provider.version .. " for id: " .. id)
    return id, M._unclaimed_provider_details[id]
end

--- TODO(Mike): Document me
function M:_get_buffer_cache_object(buffer_index, path)
    if buffer_index then
        buffer_index = "" .. buffer_index
    end
    if path == nil then
        log.error("No path was provided with index: " .. buffer_index .. '!')
        return nil
    end
    local protocol = path:match(protocol_from_path_glob)
    if protocol == nil then
        log.error("Unable to parse path: " .. path .. " to get protocol!")
        return nil
    end
    if buffer_index == nil then
        local _, provider = _cache_provider(_get_provider_for_path(path), protocol, path)
        return provider
    end
    if M._buffer_provider_cache[buffer_index] == nil then
        log.info('No cache table found for index: ' .. buffer_index .. '. Creating one now')
        M._buffer_provider_cache[buffer_index] = {}
    end
    if M._buffer_provider_cache[buffer_index][protocol] == nil then
        log.debug("No cache object associated with protocol: " .. protocol .. " for index: " .. buffer_index .. ". Attempting to claim one")

        local id = _cache_provider(_get_provider_for_path(path), protocol, path)
        return M:_claim_buf_details(buffer_index, id)
    else
        return M._buffer_provider_cache[buffer_index][protocol]
    end
end

function M:_claim_buf_details(buffer_index, details_id)
    local unclaimed_object = M._unclaimed_provider_details[details_id]
    log.debug("Claiming " .. details_id .. " and associating it with index: " .. buffer_index)
    if unclaimed_object == nil then
        log.info("Attempted to claim: " .. details_id .. " which doesn't exist...")
        return
    end
    unclaimed_object.buffer = buffer_index
    local bp_cache_object = M._buffer_provider_cache["" .. buffer_index]
    if bp_cache_object == nil then
        M._buffer_provider_cache["" .. buffer_index] = {}
        bp_cache_object = M._buffer_provider_cache["" .. buffer_index]
    end
    local existing_provider = M._buffer_provider_cache["" .. buffer_index][unclaimed_object.protocol]
    if existing_provider then
        log.info(
            "Overriding previous provider: "
            .. existing_provider._provider_path
            .. ":" .. existing_provider.version
            .. " with " .. unclaimed_object.provider.name
            .. ":" .. unclaimed_object.provider.version
            .. " for index: " .. buffer_index
        )
    end
    M._buffer_provider_cache["" .. buffer_index][unclaimed_object.protocol] = unclaimed_object
    log.debug("Claimed " .. details_id .. " and associated it with " .. buffer_index)
    M._unclaimed_provider_details[details_id] = nil
    M._unclaimed_id_table[unclaimed_object.origin_path] = nil
    log.debug("Removed unclaimed details for " .. details_id)
    return M._buffer_provider_cache["" .. buffer_index][unclaimed_object.protocol]
end

--- Write is the only entry to writing a buffers contents to a uri
--- Write reaches out to the appropriate provider associated with
--- the write_path. If the buffer does not have a matching
--- provider for the write_path, Write will auto initialize the
--- provider.
--- NOTE: Write is an asynchronous function and will return immediately
--- @param buffer_index integer
---     The index associated with the buffer being saved
--- @param write_path string
---     The string path to save to
--- @return nil
function M:write(buffer_index, write_path)
    log.debug("Saving contents of index: " .. buffer_index .. " to " .. write_path)
    local provider_details = M:_get_buffer_cache_object(buffer_index, write_path)
    log.debug("Pulled details object ", provider_details)
    log.info("Calling provider: " .. provider_details.provider._provider_path .. ":" .. provider_details.provider.version .. " to handle write")
    -- This should be done asynchronously
    provider_details.provider:write(buffer_index, write_path, provider_details.provider_cache)
end

--- Delete will reach out to the relevant provider for the delete_path
--- and call the providers `delete` function
--- @param delete_path string
---     The path to delete
--- @return nil
function M:delete(delete_path)
    local provider = _get_provider_for_path(delete_path)
    if provider == nil then
        notify.error("Unable to delete: " .. delete_path .. ". No provider was found to handle the delete!")
        return
    end
    log.info("Calling provider: " .. provider._provider_path .. ":" .. provider.version .. " to delete " .. delete_path)
    provider:delete(delete_path)
end

--- Get Metadata is the function an explorer will call (via the shim) for fetching
--- metadata associated with a URI.
--- @param uri string
---     String path representation to resolve for metadata gathering location
--- @param metadata table
---     An table (as an array) with _valid netman.options.METADATA_ entries
--- @return table
---     A table will be returned. The table will consist of the metadata input table contents
---     as the keys and the metadata associated with the key as the value
function M:get_metadata(uri, metadata)
    if not metadata then
        metadata = {}
        for key, _ in pairs(require('netman.options').explorer.METADATA) do
            table.insert(metadata, key)
        end
    end
    if not uri then
        notify.error("No uri provided!")
        return nil
    end
    local provider_details = M:_get_buffer_cache_object(nil, uri)
    if not provider_details then
        log.warn("No provider details returned for " .. uri)
        return nil
    end
    log.debug("Reaching out for metadata ", metadata)
    local return_metadata = provider_details.provider:get_metadata(uri, metadata)
    log.debug("Removing lingering Cache data for metadata request")
    M._unclaimed_provider_details[M._unclaimed_id_table[uri]] = nil
    M._unclaimed_id_table[uri] = nil
    if not return_metadata then
        log.warn("No metadata returned for " .. uri .. '!')
        return nil
    end
    local sanitized_metadata = {}
    for metadata_key, metadata_value in pairs(return_metadata) do
        if not netman_options.explorer.METADATA[metadata_key] then
            log.warn("Metadata Key" .. metadata_key .. ' is not valid. Removing...')
        else
            sanitized_metadata[metadata_key] = metadata_value
        end
    end
    return sanitized_metadata
end

--- Read is the main entry to resolving a uri and getting the contents
--- asso
--- Read is the main entry to resolving a uri and getting the contents
--- associated with it. Read reaches out to the appropriate provider
--- and retrieves valid contents.
--- Read does _not_ modify any vim buffers, nor does it modify anything
--- underneath the buffer. Modification/Displaying of data is
--- for the calling method to handle based on the return of Read
---@param buffer_index integer:
---     Vim associated integer pointing to the buffer to
---     load to. Useful for retrieving the relevant read cache
---@param path string:
---    The string path to load to resolve and load contents
---    into the buffer at the buffer_index provided
---@return string: the command to run to load the resolved contents from
---    the provided path into the buffer found at the provided buffer_index
-- TODO(Mike): Consider integration with "_claim_buf_details"
function M:read(buffer_index, path)
    if not path then
        notify.error('No path provided!')
        return nil
    end
    local provider_details = M:_get_buffer_cache_object(buffer_index, path)
    local read_data, read_type = provider_details.provider:read(path, provider_details.provider_cache)
    if read_type == nil then
        log.info("Setting read type to api.READ_TYPE.STREAM")
        log.debug("back in my day we didn't have optional return values...")
        read_type = netman_options.api.READ_TYPE.STREAM
    end
    if netman_options.api.READ_TYPE[read_type] == nil then
        notify.error("Unable to figure out how to display: " .. path .. '!')
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
    provider_details.type = read_type
    if read_type == netman_options.api.READ_TYPE.STREAM then
        log.debug("Getting stream command for path: " .. path)
        return _read_as_stream(read_data)
    elseif read_type == netman_options.api.READ_TYPE.FILE then
        provider_details.unique_name = read_data.unique_name or read_data.local_path
        provider_details.local_path = read_data.local_path
        log.debug("Setting unique name for path: " .. path .. " to " .. provider_details.unique_name)
        log.debug("Getting file command for path: " .. path)
        return _read_as_file(read_data)
    elseif read_type == netman_options.api.READ_TYPE.EXPLORE then
        if not M.explorer then
            log.error("No tree explorer loaded!")
            return
        end
        log.debug("Calling explorer to handle path: " .. path)
        return M.explorer:explore(_read_as_explore(read_data))
    end
    log.warn("Mismatched read_type. How on earth did you end up here???")
    log.debug("Ya I don't know what you want me to do here chief...")
    return nil
end

--- Load Explorer is used to set the current remote explorer to whatever package
--- is associated with `explorer_path`.
--- @param explorer_path string
---     The string path to the explorer to use
--- @param force boolean
---     A boolean to tell us if we should force the use of this explorer or not
---     NOTE: Only respected if the explorer passes validation
--- @return nil
function M:load_explorer(explorer_path, force)
    force = force or false
    local explorer = require(explorer_path)
    log.debug("Validating explorer " .. explorer_path)

    local missing_attrs = nil
    for _, required_attr in ipairs(_explorer_required_attributes) do
        if not explorer[required_attr] then
            if missing_attrs then
                missing_attrs = missing_attrs .. ', ' .. required_attr
            else
                missing_attrs = required_attr
            end
        end
    end
    if missing_attrs then
        log.error("Failed to initialize explorer: " .. explorer_path .. ". Missing the following required attributes (" .. missing_attrs .. ")")
        M._unintialized_explorers[explorer_path] = {
            reason = "Validation Failure"
           ,name = explorer_path
           ,version = "Unknown"
        }
        return
    end
    if M.explorer then
        log.info("Received new explorer " .. explorer_path .. '. Attempting to override existing explorer ' .. M.explorer._explorer_path)
        if explorer_path:find('^netman%.providers') and not force then
            log.debug(
                "Core explorer: "
                .. explorer_path .. ':' .. explorer.version
                .. ' attempted to overwrite third party'
                .. ' ' .. M.explorer._explorer_path
                .. '. Refusing...')
                goto continue

        end
        M._unintialized_explorers[explorer_path] = {
            reason = "Overriden by " .. explorer_path .. ":" .. explorer.version
            ,name = M.explorer._explorer_path
            ,version = M.explorer.version
        }
    end
    M.explorer = explorer
    if M.explorer['init'] then
        M.explorer:init()
    end
    M.explorer._explorer_path = explorer_path
    ::continue::
end

--- Unoad Provider is a function that is provided to allow a user (developer)
--- to remove a provider from Netman. This is most useful when changes have been
--- made to the provider and you wish to reflect those changes without
--- restarting Neovim
--- @param provider_path string
---    The string path to the provider
---    EG: "netman.provider.ssh"
--- @return nil
function M:unload_provider(provider_path)
    log.info("Attempting to unload provider: " .. provider_path)
    local status, provider = pcall(require, provider_path)
    package.loaded[provider_path] = nil
    if not status or provider == true or provider == false then
        log.warn("Failed to fetch provider " .. provider_path .. " for unload!")
        return
    end
    if provider.protocol_patterns then
        log.info("Disassociating Protocol Patterns and Autocommands with provider: " .. provider_path)
        for _, pattern in ipairs(provider.protocol_patterns) do
            local _, _, new_pattern = pattern:find(protocol_pattern_sanitizer_glob)
            if M._providers[new_pattern] then
                log.debug("Removing associated autocommands with " .. new_pattern .. " for provider " .. provider_path)
                if not M._unitialized_providers[provider_path] then
                    M._unitialized_providers[provider_path] = {
                        reason = "Provider Unloaded"
                        ,name = provider_path
                        ,protocol = table.concat(provider.protocol_patterns, ', ')
                        ,version = provider.version
                    }
                end
                M._providers[new_pattern] = nil
                vim.api.nvim_command('autocmd! Netman FileReadCmd '  .. new_pattern .. '://*')
                vim.api.nvim_command('autocmd! Netman BufReadCmd '   .. new_pattern .. '://*')
                vim.api.nvim_command('autocmd! Netman FileWriteCmd ' .. new_pattern .. '://*')
                vim.api.nvim_command('autocmd! Netman BufWriteCmd '  .. new_pattern .. '://*')
                vim.api.nvim_command('autocmd! Netman BufUnload '    .. new_pattern .. '://*')
            end
        end
    end
    local provider_map = {}
    for id, provider_details in pairs(M._unclaimed_provider_details) do
        if provider_details.provider._provider_path == provider_path then
            provider_map[provider_details.origin_path] = id
        end
    end
    if next(provider_map) == nil then
        log.info("Removing Provider " .. provider_path .. " from associated buffers")
        for uri, id in pairs(provider_map) do
            M._unclaimed_id_table[uri] = nil
            M._unclaimed_id_table[id] = nil
        end
    end
    return true
end

--- Reload Provider is a developer helper function that is provided for a developer
--- to quickly reload their provider into Netman without having to restart Neovim
--- @param provider_path string
---    The string path to the provider
---    EG: "netman.provider.ssh"
--- @return nil
function M:reload_provider(provider_path)
    M:unload_provider(provider_path)
    M:load_provider(provider_path)
end

--- Load Provider is what a provider should call
--- (via require('netman.api').load_provider) to load yourself
--- into netman and be utilized for uri resolution in other
--- netman functions.
--- @param provider_path string
---    The string path to the provider
---    EG: "netman.provider.ssh"
--- @return nil
function M:load_provider(provider_path)
    local status, provider = pcall(require, provider_path)
    log.debug("Attempting to import provider: " .. provider_path, {status=status})
    if not status or provider == true or provider == false then
        notify.error("Failed to initialize provider: " .. tostring(provider_path) .. ". This is likely due to it not being loaded into neovim correctly. Please ensure you have installed this plugin/provider")
        return
    end
    if provider.protocol_patterns and provider.protocol_patterns == netman_options.protocol.EXPLORE then
        log.info("Found explorer " .. provider_path .. ". Attempting load now")
        return M:load_explorer(provider_path)
    end
    provider._provider_path = provider_path
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
        M._unitialized_providers[provider_path] = {
            reason = "Validation Failure"
           ,name = provider_path
           ,protocol = "Unknown"
           ,version = "Unknown"
       }
        return
    end

    log.debug("Initializing " .. provider._provider_path .. ":" .. provider.version)
    if provider.init then
        log.debug("Found init function for provider!")
            -- TODO(Mike): Figure out how to load configuration options for providers
        local provider_config = {}
        local status, valid = pcall(provider.init, provider, provider_config)
        if not status or valid ~= true then
            log.warn(provider._provider_path .. ":" .. provider.version .. " refused to initialize. Discarding")
            M._unitialized_providers[provider_path] = {
                 reason = "Initialization Failed"
                ,name = provider_path
                ,protocol = table.concat(provider.protocol_patterns, ', ')
                ,version = provider.version
            }
            return
        end
    end
    for _, pattern in ipairs(provider.protocol_patterns) do
        local _, _, new_pattern = pattern:find(protocol_pattern_sanitizer_glob)
        log.debug("Reducing " .. pattern .. " down to " .. new_pattern)
        if M._providers[new_pattern] then
            if pattern:find('^netman%.providers') then
                log.debug(
                    "Core provider: "
                    .. provider.name
                    .. ":" .. provider.version
                    .. " attempted to overwrite third party provider: "
                    .. M._providers[new_pattern].name
                    .. ":" .. M._providers[new_pattern].version
                    .. " for protocol pattern "
                    .. new_pattern .. ". Refusing...")
                M._unitialized_providers[provider._provider_path] = {
                    reason = "Overriden by " .. M._providers[new_pattern]._provider_path .. ":" .. M._providers[new_pattern].version
                    ,name = provider._provider_path
                    ,protocol = table.concat(provider.protocol_patterns, ', ')
                    ,version = provider.version
                }
                goto continue
            end
            log.info("Provider " .. M._providers[new_pattern]._provider_path .. " is being overriden by " .. provider_path)
            M._unitialized_providers[M._providers[new_pattern]._provider_path] = {
                reason = "Overriden by " .. provider._provider_path .. ":" .. provider.version
                ,name = provider._provider_path
                ,protocol = table.concat(provider.protocol_patterns, ', ')
                ,version = provider.version
            }
            M._providers[new_pattern] = provider
            goto continue
        end
        M._providers[new_pattern] = provider
        local au_commands = {
             'autocmd Netman FileReadCmd '  .. new_pattern .. '://* lua require("netman"):read(vim.fn.expand("<amatch>"))'
            ,'autocmd Netman BufReadCmd '   .. new_pattern .. '://* lua require("netman"):read(vim.fn.expand("<amatch>"))'
            ,'autocmd Netman FileWriteCmd ' .. new_pattern .. '://* lua require("netman"):write()'
            ,'autocmd Netman BufWriteCmd '  .. new_pattern .. '://* lua require("netman"):write()'
            ,'autocmd Netman BufUnload '    .. new_pattern .. '://* lua require("netman.api"):unload(vim.fn.expand("<abuf>"))'
        }
        if not M._augroup_defined then
            vim.api.nvim_command('augroup Netman')
            vim.api.nvim_command('autocmd!')
            vim.api.nvim_command('augroup END')
            M._augroup_defined = true
        else
            log.debug("Augroup Netman already exists, not recreating augroup")
        end
        for _, command in ipairs(au_commands) do
            log.debug("Setting Autocommand: " .. command)
            vim.api.nvim_command(command)
        end
        ::continue::
    end
    M._unitialized_providers[provider_path] = nil
    log.info("Initialized " .. provider_path .. " successfully!")
end

--- Unload will inform relevant providers that a buffer is being
--- closed by the user. This will give the providers a chance
--- to close out any cache information it has associated with the
--- buffer. Additionally, Unload will clear out any cache information
--- associated with the buffer.
--- Note: this will expect the provider to handle whatever it needs
--- asynchronously (IE in the background)
--- Unload is called automatically by an autocommand
--- @param buffer_index string
---    The index of the buffer being closed
--- @return nil
function M:unload(buffer_index)
    log.info("Unload for index: " .. buffer_index .. " triggered")
   local bp_cache_object = M._buffer_provider_cache["" .. buffer_index]
   if bp_cache_object == nil then
       return
   end
   local called_providers = {}
   local provider
   for _, provider_details in pairs(bp_cache_object) do
        provider = provider_details.provider
       if called_providers[provider.name] ~= nil then
           goto continue
       end
       called_providers[provider.name] = provider
       if provider_details.type == netman_options.api.READ_TYPE.FILE and provider_details.local_path then
            utils.run_shell_command('rm ' .. provider_details.local_path)
       end
       log.info("Processing unload of " .. provider._provider_path .. ":" .. provider.version)
       if provider.close_connection ~= nil then
            log.debug("Closing connection with " .. provider._provider_path .. ":" .. provider.version)
            provider:close_connection(buffer_index, provider_details, bp_cache_object.provider_cache)
       end
       ::continue::
   end
   M._buffer_provider_cache["" .. buffer_index] = nil
end

function M:dump_info(output_path)
    if output_path ~= 'memory' then
        ---@diagnostic disable-next-line: ambiguity-1
        output_path = output_path or "$HOME/" .. utils.generate_string(10)
    end
    local neovim_details = vim.version()
    local headers = {
        '----------------------------------------------------'
        ,"Neovim Version: " .. neovim_details.major .. "." .. neovim_details.minor
        ,"System: " .. vim.loop.os_uname().sysname
        ,"Netman Version: " .. M.version
        ,""
        ,"Api Contents: " .. vim.inspect(M, {newline="\\n", indent="\\t"})
        ,">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
    }
    if M.explorer then
        table.insert(headers, 'Registered Explorer Details')
        table.insert(headers, "    " .. M.explorer._explorer_path .. " --version " .. M.explorer.version)
        table.insert(headers, '')
    end
    table.insert(headers, 'Not Registered Explorer Details')
    for _, explorer_info in pairs(M._unintialized_explorers) do
        table.insert(headers,
        "    "
        .. explorer_info.name
        .. " --version "
        .. tostring(explorer_info.version)
        .. " --reason "
        .. explorer_info.reason
        )
    end
    table.insert(headers, '')
    table.insert(headers, 'Running Provider Details')
    for pattern, provider in pairs(M._providers) do
        table.insert(headers, "    " .. tostring(provider._provider_path) .. " --pattern " .. pattern .. " --protocol " .. tostring(provider.name) .. " --version " .. tostring(provider.version))
    end
    table.insert(headers, "")
    table.insert(headers, "Not Running Provider Details")
    for provider, provider_info in pairs(M._unitialized_providers) do
        table.insert(headers,
            "    "
            .. provider
            .. " --protocol "
            .. tostring(provider_info.name)
            .. " --version "
            .. tostring(provider_info.version)
            .. " --reason "
            .. tostring(provider_info.reason)
        )
    end
    table.insert(headers, '----------------------------------------------------')
    table.insert(headers, 'Logs:')
    table.insert(headers, '')
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
    local logs = utils.generate_session_log(output_path, headers)
    vim.api.nvim_buf_set_lines(log_buffer, 0, -1, false, logs)
    vim.api.nvim_command('%s%\\\\n%\r%g')
    vim.api.nvim_command('%s%\\\\t%\t%g')
    vim.api.nvim_buf_set_option(log_buffer, 'modifiable', false)
    vim.api.nvim_buf_set_option(log_buffer, 'modified', false)
    vim.api.nvim_command('0')
end

function M:init(core_providers)
    if M._initialized then
        return
    end
    local _core_providers = require('netman.providers')
    core_providers = core_providers or _core_providers
    log.info("Initializing Netman API")
    for _, provider in ipairs(core_providers) do M:load_provider(provider) end
    M._initialized = true
    vim.g.netman_api_initialized = true
end


-- I am not super fond of this, but it is how the busted framework
-- says to handle unit testing of internal methods
-- http://olivinelabs.com/busted/#private
---@diagnostic disable-next-line: undefined-global
if _UNIT_TESTING then
    M._read_as_stream          = _read_as_stream
    M._read_as_file            = _read_as_file
    M._read_as_explore         = _read_as_explore
    M._get_provider_for_path   = _get_provider_for_path
end

M:init()
return M
