--- Lua and Neovim compatibility library

-- Planning ahead for if/when Neovim deprecates this :/
if table.unpack then unpack = table.unpack end

return {
    unpack = unpack
}
