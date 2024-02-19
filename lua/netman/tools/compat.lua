--- Lua and Neovim compatibility library

-- Planning ahead for if/when Neovim deprecates this :/
local unpack = unpack
local uv     = nil
local mkdir  = nil
local delete = nil
local os =
    vim.loop.os_uname().sysname:lower():match('windows') and 'windows'
    or vim.loop.os_uname().sysname:lower():match('linux') and 'linux'
    or vim.loop.os_uname().sysname:lower():match('darwin') and 'macos'

local sep = os == 'windows' and '\\' or '/' -- \ for windows, mac and linux both use \
if table.unpack then unpack = table.unpack else table.unpack = unpack end
if vim and vim.loop then
    uv = vim.loop
else
    uv = require("luv")
end
if vim and vim.fn then
    mkdir = vim.fn.mkdir
    delete = vim.fn.delete
else
    mkdir  = function(name, path, prot)

        -- Probably should make this also work on windows but I don't care right now
        -- If prot is provided, lop off the leading 0o, we don't care about it
        if prot then prot = prot:match('0o(.*)') else prot = "755" end
        -- convert the prot to an octal
        prot = tonumber(prot, 8)
        local success = true
        if path then
            local broken_path = {}
            for node in name:gmatch(string.format('[^%s]+', sep)) do
                table.insert(broken_path, node)
                local mkdir_success, _, err = uv.mkdir(table.concat(broken_path, sep), prot)
                -- Check to see if the directory exists first. Could also
                -- do a stat but meh, this should be fine
                if not mkdir_success and err ~= 'EEXIST' then
                    -- Make dir failed somehow!
                    success = false
                    break
                end
            end
        else
            success = uv.mkdir(path, prot)
        end
        -- Compatibility with vim.fn.mkdir
        if not success then return 0 else return 1 end
    end
    delete = function(name, flags)

    end
end

return {
    unpack = unpack,
    uv     = uv,
    mkdir  = mkdir,
    delete = delete,
    sep    = sep,
    os     = os
}
