local utils = require('netman.utils')
local netman_options = require('netman.options')
local log = utils.log
local notify = utils.notify

local protocol_pattern_sanitizer_glob = '[%%^]?([%w-.]+)[:/]?'
local protocol_from_path_glob = '^([%w-.]+)://'

-- TODO(Mike): Potentially implement auto deprecation/enforcement here?
local _provider_required_attributes = {
    'name'
    ,'protocol_patterns'
    ,'version'
    ,'read'
    ,'write'
    ,'delete'
}

local M = {}

M.version = "0.1"
M._augroup_defined = false
M._initialized = false
M._setup_commands = false
M.READ_TYPE = {
    FILE   = 'FILE'
    ,STREAM = 'STREAM'
}
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
    local command = "0append! " .. table.concat(stream, '\n')
    log.debug("Generated read stream command: " .. command:sub(1, 30))
    return command
end

local _read_as_file = function(file)
    -- TODO(Mike): Should still handle lock files for the files as they are pulled
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

local _cache_provider = function(provider, protocol, path)
    log.debug("Reaching out to provider: " .. provider._provider_path .. ":" .. provider.version .. " to initialize connection for path: " .. path)
    local id = utils.generate_string(10)
    local bp_cache_object = {
        provider        = provider
        ,protocol       = protocol
        ,origin_path    = path
        -- ,buffer         = buffer_index
    }
    M._unclaimed_provider_details[id] = bp_cache_object
    M._unclaimed_provider_details[id].buffer = nil
    M._unclaimed_provider_details[id].provider_cache = {}
    M._unclaimed_id_table[path] = id
    log.debug("Cached provider: " .. provider._provider_path .. ":" .. provider.version .. " for id: " .. id)
    return id, M._unclaimed_provider_details[id]
end

--- TODO(Mike): Document me
local _get_buffer_cache_object = function(buffer_index, path)
    log.debug("_get_buffer_cache_object ", {buffer_index=buffer_index, path=path})
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
    local provider_details = _get_buffer_cache_object(buffer_index, write_path)
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
    local provider_details = _get_buffer_cache_object(buffer_index, path)
    local read_data, read_type = provider_details.provider:read(path, provider_details.provider_cache)
    if read_type == nil then
        log.info("Setting read type to api.READ_TYPE.STREAM")
        log.debug("back in my day we didn't have optional return values...")
        read_type = M.READ_TYPE.STREAM
    end
    if M.READ_TYPE[read_type] == nil then
        notify.error("Unable to figure out how to display: " .. path .. '!')
        log.warn("Received invalid read type: " .. read_type .. ". This should be either api.READ_TYPE.STREAM or api.READ_TYPE.FILE!")
        return nil
    end
    if read_data == nil then
        log.warn("Received nothing to display to the user, this seems wrong but I just do what I'm told...")
    end
    if type(read_data) ~= 'table' then
        log.warn("Data returned is not in a table. Attempting to make it a table")
        log.debug("grumble grumble, kids these days not following spec...")
        read_data = {read_data}
    end
    if read_type == M.READ_TYPE.STREAM then
        log.debug("Getting stream command for path: " .. path)
        return _read_as_stream(read_data)
    elseif read_type == M.READ_TYPE.FILE then
        log.debug("Getting file command for path: " .. path)
        return _read_as_file(read_data)
    end
    log.warn("Mismatched read_type. How on earth did you end up here???")
    log.debug("Ya I don't know what you want me to do here chief...")
    return nil
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
    if not status then
        notify.error("Failed to initialize provider: " .. tostring(provider_path) .. ". This is likely due to it not being loaded into neovim correctly. Please ensure you have installed this plugin/provider")
        return
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
        if not provider:init({}) then
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
        -- TODO(Mike): These will fail without being implemented
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
       log.info("Processing unload of " .. provider._provider_path .. ":" .. provider.version)
       if provider.close_connection ~= nil then
            log.debug("Closing connection with " .. provider._provider_path .. ":" .. provider.version)
            provider:close_connection(buffer_index, provider_details)
       end
       ::continue::
   end
   M._buffer_provider_cache["" .. buffer_index] = nil
end

function M:dump_info(output_path)
---@diagnostic disable-next-line: ambiguity-1
    output_path = output_path or "$HOME/" .. utils.generate_string(10)
    local neovim_details = vim.version()
    local headers = {
        '----------------------------------------------------'
        ,"Neovim Version: " .. neovim_details.major .. "." .. neovim_details.minor
        ,"System: " .. vim.loop.os_uname().sysname
        ,"Netman Version: " .. M.version
        ,""
        ,"Running Provider Details"
    }
    for pattern, provider in pairs(M._providers) do
        table.insert(headers, "    " .. provider._provider_path .. " --pattern " .. pattern .. " --protocol " .. provider.name .. " --version " .. provider.version)
    end
    table.insert(headers, "")
    table.insert(headers, "Not Running Provider Details")
    for provider, provider_info in pairs(M._unitialized_providers) do
        table.insert(headers,
            "    "
            .. provider
            .. " --protocol "
            .. provider_info.name
            .. " --version "
            .. provider_info.version
            .. " --reason "
            .. provider_info.reason
        )
    end
    table.insert(headers, '----------------------------------------------------')
    utils.generate_session_log(output_path, headers)
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
    M._read_as_stream = _read_as_stream
    M._read_as_file = _read_as_file
    M._get_provider_for_path = _get_provider_for_path
    M._get_buffer_cache_object = _get_buffer_cache_object

    M._utils = utils
end

M:init()
return M
