local remote_tools = require('netman.remote_tools')
local utils        = require('netman.utils')
local notify       = utils.notify

local default_options = {
    allow_netrw     = false,
    keymaps         = {}, -- TODO(Mike): Figure this out
    DEBUG           = true,
    quiet           = false, -- TODO(Mike): Notate this
}

local cache_dir = vim.fn.stdpath('cache') .. "/netman/remote_files/"

local override_netrw = function()
    if vim.g.loaded_netman then
        return
    end
    vim.g.loaded_netrw = 1
    vim.g.loaded_netrwPlugin = 1
    vim.g.loaded_netman = 1 -- TODO(Mike) By disabling netrw, we prevent ANY netrw handling of files. This is probably bad, we may want to consider a way to allow some of NetRW to function.
    -- EG, this disables NetRW's local directory handling which is not amazing. 
    -- Alternatively, we build our own internal file handling...?
    vim.api.nvim_command('augroup Netman')
    vim.api.nvim_command('autocmd!')
    vim.api.nvim_command('autocmd VimEnter sil! au! FileExplorer *')
    vim.api.nvim_command('autocmd FileReadCmd sftp://*,scp://*,rsync://* lua Nmread(vim.fn.expand("<amatch>"), "file")')
    vim.api.nvim_command('autocmd BufReadCmd sftp://*,scp://*,rsync://* lua Nmread(vim.fn.expand("<amatch>"), "buf")')
    vim.api.nvim_command('augroup END')
end

local browse = function(path, remote_info, display_results)
    display_results = display_results or false
    remote_info = remote_info or remote_tools.get_remote_details(path)
    contents = remote_tools.get_remote_files(remote_info, path)
    if not display_results then
        return contents
    end
    -- TODO(Mike): Figure out how to display this?
    for type, subtable in pairs(contents) do
        for subtype, array in pairs(subtable) do
            for _, info in ipairs(array) do
                notify("Received: " .. type .. '|' .. subtype .. '|' .. info.full_path, vim.log.levels.INFO)
            end
        end
    end
end

local read = function(path)
    local remote_info = remote_tools.get_remote_details(path)
    if not remote_info.protocol then
        return
    end
    local file_location, read_command = remote_tools.get_remote_file(path, cache_dir, remote_info)
    vim.api.nvim_command('keepjumps sil! 0')
    vim.api.nvim_command('keepjumps execute "sil! read ++edit !' .. read_command .. '"')
    vim.api.nvim_command('keepjumps sil! 0d')
    vim.api.nvim_command('keepjumps sil! 0')
end

local write = function(path)
    print("Saving Path: " .. path)
end

local delete = function(path)
    print("Deleting Path: " .. path)
end

local create = function(path)
    print("Creating Path: " .. path)
end

local export_functions = function()
    _G.Nmbrowse = browse
    _G.Nmread   = read
    _G.Nmwrite  = write
    _G.Nmdelete = delete
    _G.Nmcreate = create
end

local setup = function(options)
    local opts = {}
    for key, value in pairs(default_options) do
        opts[key] = value
    end
    
    if options then
       for key, value in pairs(options) do
            opts[key] = value
        end
    end

    vim.fn.mkdir(cache_dir, 'p')
    export_functions()
    if not opts.allow_netrw then
        override_netrw()
    end
end

return {
    setup  = setup,
    read   = read,
    write  = write,
    delete = delete,
    create = create,
}
