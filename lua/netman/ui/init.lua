local logger = require("netman.api").get_system_logger()
local compat = require("netman.tools.compat")
local UI_EVENTS = require("netman.tools.options").ui.EVENTS
local M = {
    internal = {},
}

M.internal.STATE_REFRESH_RATE = 15000
M.internal.registered_explore_consumer = nil
M.internal.state_update_callbacks = {}
M.internal.previous_host_states = {}

function M.get_logger()
    return require("netman.api").get_consumer_logger()
end

function M.internal.check_states()
    if not next(M.internal.previous_host_states) then
        -- Nothing to do here
        return
    end
    local api = require("netman.api")
    for host_uri, host_details in pairs(M.internal.previous_host_states) do
        local new_state = host_details.checker()
        logger.debug("Comparing", new_state, "to old state", host_details.state)
        if new_state ~= host_details.state then
            host_details.state = new_state
            api.emit_event(UI_EVENTS.STATE_CHANGED, "netman.ui", {
                new_state = new_state,
                uri = host_uri
            })
        end
    end
end

--- Reaches into Netman API and provides a table of providers.
--- Each Key is the provider's display name and the value will be
--- a table containing relevant keys.
--- EG
--- {
---     docker = {
---         ui = {
---             icon = "",
---             highlight = ""
---         },
---         hosts = <function>,
---         path = "netman.providers.docker"
---     },
---     ssh = {
---         ui = {
---             icon = "",
---             highlight = ""
---         },
---         hosts = <function>,
---         path = "netman.providers.ssh"
---     }
--- }
---
--- The `host` function is a lazy function designed to be able to
--- repeatedly (and lazily) fetch a table of hosts and functions to get each host's current state.
--- These state fetching functions have the following signature
--- function() -> {
---     id = String: This will be the URI to access the host,
---     name = String: The "name" of the host,
---     state = String: A "state" the host is currently in. See netman.tools.options.ui.STATES for valid states,
---     last_access = String: may be nil if the provider doesn't report, otherwise, this will be the last time this host was accessed by the user,
---     uri = String: The URI to access the host,
---     entrypoint = Table|Function: This may be a 1 Dimensional table of URIs to "navigate" to in order to reach the entrypoint of the host. If this is a function, the provider likely needs to fetch this from the host itself. If it is a function, it will (when called) return this same 1 Dimensional table of URIs to "navigate" to
--- }
function M.get_providers()
    logger.trace("Fetching Netman Providers")
    local api = require("netman.api")
    local providers = {}
    for _, provider_path in ipairs(api.providers.get_providers()) do
        local provider_details = {
            hosts = nil, -- Stubbing this for clarity more than anything
            ui = {
                icon = '',
                highlight = ''
            },
            path = provider_path
        }
        local status, provider = pcall(require, provider_path)
        if not status or not provider.ui then
            if not status then
                logger.warnf("Unable to import %s -> %s", provider_path, provider)
            end
            if provider and not provider.ui then
                logger.infof("%s is not ui ready, it is missing the optional ui attribute", provider_path)
                goto continue
            end
        end
        logger.tracef("Generating lazy function for repeated host fetching of %s", provider_path)
        -- TODO: Add async support?
        provider_details.hosts = function(callback)
            logger.tracef("Reaching out to get hosts for %s", provider_path)
            local hosts = {}
            local raw_hosts = api.providers.get_hosts(provider_path)
            if not raw_hosts then
                logger.infof("No hosts returned for %s", provider_path)
                return hosts
            end
            for _, host in ipairs(raw_hosts) do
                hosts[host] = function()
                    local raw_details = api.providers.get_host_details(provider_path, host)
                    if not raw_details then
                        logger.warnf("%s did not return any details for %s", provider_path, host)
                        return nil
                    end
                    local state_callback = raw_details.STATE
                    local wrapped_state_callback = function(force)
                        if M.internal.previous_host_states[host] and not force then
                            return M.internal.previous_host_states[host].state
                        end
                        local new_state = state_callback and state_callback() or ''
                        M.internal.previous_host_states[raw_details.URI] = {
                            state = new_state,
                            checker = state_callback or function() return '' end
                        }
                        return new_state
                    end
                    return {
                        id = raw_details.URI,
                        name = raw_details.NAME,
                        state = wrapped_state_callback,
                        last_access = raw_details.LAST_ACCESSED,
                        uri = raw_details.URI,
                        os = raw_details.OS,
                        entrypoint = raw_details.ENTRYPOINT
                    }
                end
            end
            if callback then
                callback(hosts)
            else
                return hosts
            end
        end
        provider_details.ui.icon = provider.ui.icon or ''
        provider_details.ui.highlight = provider.ui.highlight or ''
        providers[provider.name] = provider_details
        ::continue::
    end
    return providers
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
        logger.info(string.format("Creating new UI configuration for %s", consumer))
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

function M.get_least_common_path(paths)
    -- Walk through each path list
    -- Add each path to a flatmap. 
    -- If the path has a parent, remove the parent from its parent
    -- Purge all items in flatmap that have no children
    -- Return the keys remaining
    local flatmap = {}
    for _, pathlist in ipairs(paths) do
        local parent_path = nil
        for depth, path in ipairs(pathlist) do
            local parent_node = flatmap[parent_path]
            if not flatmap[path] then
                flatmap[path] = {
                    parent = parent_path,
                    children = {},
                    depth = depth,
                    path = path
                }
            end
            if parent_node then
                parent_node.children[path] = true
                if parent_node.parent then
                    flatmap[parent_node.parent].children[parent_path] = nil
                end
            end
            parent_path = path
        end
    end
    local unsorted_return_keys = {}
    for _, details in pairs(flatmap) do
        local parent = flatmap[details.parent]
        if next(details.children) ~= nil and (not parent or (parent and not next(parent.children))) then
            table.insert(unsorted_return_keys, details)
        end
    end
    table.sort(unsorted_return_keys, function(a, b) return a.depth < b.depth end)
    local return_keys = {}
    for _, details in ipairs(unsorted_return_keys) do
        table.insert(return_keys, details.path)
    end
    return return_keys
end

function M.render_command_and_clean_buffer(render_command, opts)
    opts = {
        nomod = 1,
        detect_filetype = 1
    } or opts
    local undo_levels = vim.api.nvim_get_option('undolevels')
    vim.api.nvim_command('keepjumps sil! 0')
    -- Addresses #133, basically saying "ya we don't care if the read event has an
    -- error, deal with it and move on"
    local _, err pcall(vim.api.nvim_command, 'keepjumps sil! setlocal ul=-1 | ' .. render_command)
    if err then
        logger.tracef("Encountered potential error while trying to execute %s: -> %s", render_command, err)
    end
    -- if opts.filetype then
    --     vim.api.nvim_command(string.format('set filetype=%s', opts.filetype))
    -- end
    -- TODO: (Mike): This actually adds the empty line to the default register. consider a way to get
    -- 0"_dd to work instead?
    vim.api.nvim_command('keepjumps sil! 0d')
    vim.api.nvim_command('keepjumps sil! setlocal ul=' .. undo_levels .. '| 0')
    if opts.nomod then
        vim.api.nvim_command('sil! set nomodified')
    end
    if opts.detect_filetype then
        vim.api.nvim_command('sil! filetype detect')
    end
end

-- Sets the provided callback as an async callback within the netman api.
-- This means that any read request made that does _not_ provide a callback of their own will instead go here
-- @param consumer_name string
--     The name of the consumer. This can be any arbitrary name though convention would be the require path
-- @param callback function
--     A function to use as the default callback. This function will trigger reads with no callback in the API
--     to instead asynchronously pass to this
function M.register_explorer_consumer(consumer_name, callback)
    if M.internal.registered_explore_consumer then
        logger.warnf("A new consumer is replacing the existing explorer consumer!")
        logger.infof("New Consumer", consumer_name, "-- Old Consumer", M.internal.registered_explore_consumer.name)
    end
    logger.infof("Setting netman default explore callback to", consumer_name)
    M.internal.registered_explore_consumer = { name = consumer_name, callback = callback }
    require("netman.api").internal.registered_explore_consumer = callback
end

local function setup()
    if M.internal.__setup then return end
    M.internal.update_timer = compat.uv.new_timer()
    -- Runs update check every minute. Maybe we want a lower number?
    M.internal.update_timer:start(0, M.internal.STATE_REFRESH_RATE, M.internal.check_states)
    M.internal.__setup = true
end

setup()
return M
