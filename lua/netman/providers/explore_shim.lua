local netman_options = require("netman.options")
local utils = require("netman.utils")
local log = utils.log
local required_fields = netman_options.explorer.FIELDS
local metadata_fields = netman_options.explorer.METADATA
local M = {}
M._cache = {}
M.version = 0.1
M.protocol_patterns = netman_options.protocol.EXPLORE


function M:init()
    --- Note: (Mike): I am not super fond of this, however it will resolve issue https://github.com/miversen33/netman.nvim/issues/41
    log.info("Disabling Netrw")
    vim.g.loaded_netrwPlugin = 1
    vim.g.loaded_netrw = 1
end

-- To make this work, consider a dual system where we _push_ information
-- into the explorer (via "some" function) and then explorer
-- reaches back into the shim to get details on what to do next.
-- This is likely to reflect how most explorers would operate
-- and be the easiest to shim in between it and the underlying
-- operating system

-- explore should take in the "raw" data as provided to it by
-- the API. It should then meld that into something "usable"
-- by the explorer. Thus the shim will do alot of the heavy
-- work on making the output from the API into something usable
-- for your explorer. @see netman.options.explorer.METADATA
-- for available METADATA flags. Note, anything not listed in these
-- flags will be scrubbed by the API
-- @param explore_details Table
--     A table object (as an array) that will contain
--     tables within with various metadata bits to be used to
--     format and display content
-- @return nil
function M:explore(explore_details)
    local netman_explorer = require("netman.providers.explorer")
    local parent = explore_details.parent
    local details = explore_details.details
    for _, detail in ipairs(details) do
        local title = detail[netman_options.explorer.FIELDS.NAME]
        detail.title = title
    end
    M._cache = explore_details
    log.debug("Launching Explorer!")
    netman_explorer:explore(parent, details)
end

function M:interact_via_event(index)
    log.info("Received Index: " .. index, {cache = M._cache[index]})
end

function M:interact_via_callback(uri)
    log.info("Opening URI: " .. uri)
    require("netman"):read(uri)
end

return M
