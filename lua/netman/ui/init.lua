local logger = require("netman.api").get_system_logger()
local M = {
    internal = {},
    get_logger = require("netman.api").get_consumer_logger
}

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
                    return {
                        id = raw_details.URI,
                        name = raw_details.NAME,
                        state = raw_details.STATE,
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

return M
