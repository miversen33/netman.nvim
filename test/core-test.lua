package.path = "../?.lua;" .. package.path -- Adding netman itself to the import path
_G._QUIET = true -- This makes bootstrap shut up
require("lua.netman.tools.bootstrap")
vim.g.netman_log_level = 0
require("netman.tools.utils").log.warn("Beginning Unit Tests!")
require("core.api_spec")
