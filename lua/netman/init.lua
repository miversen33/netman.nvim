local default_options = {
    allow_netrw     = false,
    keymaps         = {}, -- TODO(Mike): Figure this out
    DEBUG           = true,
}

local override_netrw = function()
    vim.g.loaded_netrwPlugin = 1 -- Bypasses Netrw
    vim.api.nvim_command('augroup Netman')
    vim.api.nvim_command('autocmd!')
    vim.api.nvim_command('autocmd VimEnter sftp://*,scp://* lua Nmread(vim.fn.expand("<amatch>"))')
    -- vim.api.nvim_command('autocmd BufWritePost * lua Nmwrite(vim.fn.expand("<amatch>"))')
    -- vim.api.nvim_command('autocmd BufReadCmd * lua Nmread(vim.fn.expand("<amatch>"))')
    vim.api.nvim_command('autocmd FileReadCmd sftp://*,scp://* lua Nmread(vim.fn.expand("<amatch>"))')
    vim.api.nvim_command('augroup END')
end

local read = function(path)
    print("Reading Path: " .. path)
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
    _G.Nmread = read
    _G.Nmwrite = write
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

    vim.fn.mkdir(vim.fn.stdpath('cache') .. "/netman/remote_files", 'p')
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
