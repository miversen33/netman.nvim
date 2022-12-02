--- Lua and Neovim compatibility library

-- Planning ahead for if/when Neovim deprecates this :/
local unpack = unpack
if table.unpack then unpack = table.unpack end

-- Compat layer for using the same "uv" stuff 
-- regardless of if we are running in neovim or lua
local uv = nil
if vim then uv = vim.loop else uv = require("luv") end

return {
    unpack = unpack,
    uv     = uv
}
