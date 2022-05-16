local log = require("netman.utils").log
local api = require('netman.api')
local metadata_flags = require("netman.options").explorer.METADATA
local tick_limit = require("netman.options").utils.LRU_CACHE_TICK_LIMIT
-- Planning ahead for if/when Neovim deprecates this :/
if table.unpack then unpack = table.unpack end

local M = {}

local package_name_escape = "([\\(%s@!\"\'\\)-.])"

M._lru_cache = {}

M._inited = false
M.overriden_callers = {}
M._overriden_callers = {}
M._file_descriptor_map = {}
M._path_map = {}
M._file_index = 0 -- Hopefully this avoids potential libuv overlap on file descriptors?
M._explorer_shim = {
    _cached_explorer = nil,
    _current_file_descriptor = M._file_index,
    _explore_cache = {},
    _parent = nil,
    explore = function(_, path, details)
        -- Consider removing parent?
        M._explorer_shim._parent = details.parent
        local count = 1
        for _, item in ipairs(details.details) do
            if count ~= details.parent then
                if item.FIELD_TYPE == metadata_flags.DESTINATION then
                    table.insert(M._explorer_shim._explore_cache, {name=item.NAME, typ='file'})
                else
                    table.insert(M._explorer_shim._explore_cache, {name=item.NAME, typ='directory'})
                end
            end
            count = count + 1
        end
        log.debug("Explore Cache ", M._explorer_shim._explore_cache)
    end,
    next = function()
        if not next(M._explorer_shim._explore_cache) then
            return nil
        end
        local item = table.remove(M._explorer_shim._explore_cache, 1)
        return item.name, item.typ
    end,
    clear = function()
        M._explorer_shim._explore_cache = {}
        M._explorer_shim._current_file_descriptor = 0
    end
}

function M.fs_access(path, mode, callback)
    if (path:sub(1,1) == '/')
        or (
            path:sub(1,1) == '.'
            and api:cwd():sub(1,1) == '/'
        )
    then return M._hidden_functions['fs_access'](path, mode, callback) end
    return true
end

function M.cwd()
    return api:cwd()
end

function M.fs_realpath(path, callback)
    if (path:sub(1,1) == '/')
        or (
            path == '.'
            and api:cwd():sub(1,1) == '/'
        )
    then return M._hidden_functions['fs_realpath'](path, callback) end
    if path == '.' then path = api:cwd() else path = api:repair_uri(path) end
    if callback then callback(nil, path) else return path end
end


function M.fs_open(path, flags, mode, callback)
    if (path:sub(1,1) == '/')
        or (
            path:sub(1,1) == '.'
            and api:cwd():sub(1,1) == '/'
        )
    then return M._hidden_functions['fs_open'](path, flags, mode, callback) end
    M._explorer_shim.clear()
    if M._path_map[path] then return M._path_map[path] end
    M._file_index = M._file_index - 1
    M._path_map[path] = M._file_index
    M._file_descriptor_map[M._file_index] = path
    return M._file_index
end

function M.fs_scandir(path, callback)
    if (path:sub(1,1) == '/')
        or (
            path:sub(1,1) == '.'
            and api:cwd():sub(1,1) == '/'
        )
    then return M._hidden_functions['fs_scandir'](path, callback) end
    if not M._path_map[path] then return M.fs_open(path, nil, nil, callback) end
    return M._path_map[path]
end

function M.fs_scandir_next(file_descriptor)
    local path = M._file_descriptor_map[file_descriptor]
    if path then
        local needs_fetch = false
        if M._explorer_shim._current_file_descriptor ~= file_descriptor then
            M._explorer_shim._current_file_descriptor = file_descriptor
            -- Test the performance of this vs other ways to clear this cache out
            M._explorer_shim._explore_cache = {}
            needs_fetch = true
        end
        if needs_fetch then
            if api.explorer and api.explorer ~= M._explorer_shim then
                M._explorer_shim._cached_explorer = api.explorer
            end
            api.explorer = M._explorer_shim
            api:read(nil, path)
        end
        return M._explorer_shim.next()
    end
    return M._hidden_functions['fs_scandir_next'](file_descriptor)
    -- https://github.com/luvit/luv/blob/master/docs.md#uvfs_scandir_nextfs
end

function M.fs_fstat(file_descriptor, callback)
    local path = M._file_descriptor_map[file_descriptor]
    if path then
        return M.fs_stat(path, callback)
    end
    return M._hidden_functions['fs_fstat'](file_descriptor, callback)
    -- if not M._file_descriptors[file_descriptor] then return M._hidden_functions['fs_fstat'](file_descriptor, callback) end
end

function M.fs_read(file_descriptor, size, offset, callback)
    -- log.debug("Input: ", {params={file_descriptor=file_descriptor, size=size, offset=offset, callback=callback}})
    return M._hidden_functions['fs_read'](file_descriptor, size, offset, callback)
    -- if not M._file_descriptors[file_descriptor] then return M._hidden_functions['fs_read'](file_descriptor, size, offset, callback) end
end

function M.fs_stat(path, callback)
    -- https://github.com/luvit/luv/blob/master/docs.md#uvfs_statpath-callback
    -- Make metadata returned match what is listed here
    if (path:sub(1,1) == '/')
        or (
            path:sub(1,1) == '.'
            and api:cwd():sub(1,1) == '/'
    ) then return M._hidden_functions['fs_stat'](path, callback) end
    local metadata = api:get_metadata(path)
    if callback then callback(nil, metadata) else return metadata end
    -- local metadata = api:get_metadata(path)
    -- if callback then callback(nil, metadata) else return metadata end
end

function M.fs_mkdir(path, mode, callback)
    -- log.debug("Input: ", {params={path=path, mode=mode, callback=callback}})
    return M._hidden_functions['fs_mkdir'](path, mode, callback)
    -- if path:sub(1,1) == '/' then return M._hidden_functions['fs_mkdir'](path, mode, callback) end
    -- local mkdir_status = api:write(nil, path)
    -- if callback then callback(nil, true) else return true end
end

function M.fs_rmdir(path, callback)
    -- log.debug("Input: ", {params={path=path, callback=callback}})
    return M._hidden_functions['fs_rmdir'](path, callback)
    -- if path:sub(1,1) == '/' then return M._hidden_functions['fs_rmdir'](path, callback) end
    -- local rmdir_status = api:delete(path)
    -- if callback then callback(nil, true) else return true end
end

function M.fs_close(file_descriptor, callback)
    -- log.debug("Input: ", {params={file_descriptor=file_descriptor, callback=callback}})
    return M._hidden_functions['fs_close'](file_descriptor, callback)
    -- if not M._file_descriptors[file_descriptor] then return M._hidden_functions['fs_close'](file_descriptor, callback) end
    -- https://github.com/luvit/luv/blob/master/docs.md#uvfs_closefd-callback
    -- consider having this reach out to require("netman"):close()??
    -- log.debug("File Descriptor", file_descriptor)
end

function M.fs_rename(path, new_path, callback)
    -- log.debug("Input: ", {params={path=path, new_path=new_path, callback=callback}})
    return M._hidden_functions['fs_rename'](path, new_path, callback)
    -- if path:sub(1,1) == '/' then return M._hidden_functions['fs_rename'](path, new_path, callback) end
    -- -- https://github.com/luvit/luv/blob/master/docs.md#uvfs_renamepath-new_path-callback
    -- -- We should probably have a "rename" method in api
    -- log.debug("Input ", {path=path, new_path=new_path})
end

function M.fs_copyfile(path, new_path, flags, callback)
    -- log.debug("Input: ", {params={path=path, new_path=new_path, flags=flags, callback=callback}})
    return M._hidden_functions['fs_copyfile'](path, new_path, callback)
    -- if path:sub(1,1) == '/' then return M._hidden_functions['fs_copyfile'](path, new_path, callback) end
    -- -- https://github.com/luvit/luv/blob/master/docs.md#uvfs_copyfilepath-new_path-flags-callback
    -- log.debug("Input ", {path=path, new_path=new_path, flags=flags})
end

function M.fs_unlink(path, callback)
    -- log.debug("Input: ", {params={path=path, callback=callback}})
    return M._hidden_functions['fs_unlink'](path, callback)
    -- if path:sub(1,1) == '/' then return M._hidden_functions['fs_unlink'](path, callback) end
    -- return M.fs_rmdir(path, callback)
end

function M.getcwd()
    -- log.debug("Input: ")
    return M._hidden_functions['getcwd']()
end

function M.fs_chmod(path, mode, callback) return M._hidden_functions['fs_chmod'](path, mode, callback)end
function M.fs_chown(path, uid, gid, callback) return M._hidden_functions['fs_chown'](path, uid, gid, callback)end
function M.fs_closedir(dir, callback) return M._hidden_functions['fs_closedir'](dir, callback)end
function M.fs_fchmod(fd, mode, callback) return M._hidden_functions['fs_fchmod'](fd, mode, callback)end
function M.fs_fchown(fd, uid, gid, callback) return M._hidden_functions['fs_fchown'](fd, uid, gid, callback)end
function M.fs_fdatasync(fd, callback) return M._hidden_functions['fs_fdatasync'](fd, callback)end
function M.fs_fsync(fd, callback) return M._hidden_functions['fs_fsync'](fd, callback)end
function M.fs_ftruncate(fd, offset, callback) return M._hidden_functions['fs_ftruncate'](fd, offset, callback)end
function M.fs_futime(fd, atime, mtime, callback) return M._hidden_functions['fs_futime'](fd, atime, mtime, callback)end
function M.fs_lchown(fd, uid, gid, callback) return M._hidden_functions['fs_lchown'](fd, uid, gid, callback)end
function M.fs_link(path, newpath, callback) return M._hidden_functions['fs_link'](path, newpath, callback)end
function M.fs_lutime(path, atime, mtime, callback) return M._hidden_functions['fs_lutime'](path, atime, mtime, callback)end
function M.fs_lstat(path, callback) return M._hidden_functions['fs_lstat'](path, callback) end
function M.fs_mkdtemp(template, callback) return M._hidden_functions['fs_mkdtemp'](template, callback)end
function M.fs_mkstemp(template, callback) return M._hidden_functions['fs_mkstemp'](template, callback)end
function M.fs_opendir(path, callback, entries) return M._hidden_functions['fs_opendir'](path, callback, entries)end
function M.fs_readdir(dir, callback) return M._hidden_functions['fs_readdir'](dir, callback)end
function M.fs_readlink(path, callback) return M._hidden_functions['fs_readlink'](path, callback)end
function M.fs_sendfile(out_fd, in_fd, in_offset, size, callback) return M._hidden_functions['fs_sendfile'](out_fd, in_fd, in_offset, size, callback)end
function M.fs_statfs(path, callback) return M._hidden_functions['fs_statfs'](path, callback)end
function M.fs_symlink(path, new_path, flags, callback) return M._hidden_functions['fs_symlink'](path, new_path, flags, callback)end
function M.fs_utime(path, atime, mtime, callback) return M._hidden_functions['fs_utime'](path, atime, mtime, callback)end
function M.fs_write(fd, data, offset, callback) return M._hidden_functions['fs_write'](fd, data, offset, callback)end

function M:override_from_caller(caller)
    if not M._overriden_callers[caller] then
        log.info("Overriding Libuv calls from " .. caller .. " for remote resources")
        local _caller = caller:gsub(package_name_escape, '%%' .. '%1')
        M.overriden_callers[caller] = _caller
        M._overriden_callers[_caller] = 1
    end
end

function M:remove_override_from_caller(caller)
    if M.overriden_callers[caller] then
        M._overriden_callers[M.overriden_callers[caller]] = nil
        M.overriden_callers[caller] = nil
    end
end

M._override_functions = {
    cwd             = M.cwd, -- We need a way to track this, though I am not sold on the best way
    fs_access       = M.fs_access, -- should probably just return true?
    fs_close        = M.fs_close, -- should map (more or less) to netman.api.unload
    fs_fstat        = M.fs_fstat, -- Dont have a great way of dealing with this, likely via get_metadata
    fs_open         = M.fs_open, -- should map (more or less) to netman.api.read
    fs_read         = M.fs_read, -- This is going to be a big pain in the ass :/
    fs_realpath     = M.fs_realpath, -- should return the URI
    fs_scandir      = M.fs_scandir,
    fs_scandir_next = M.fs_scandir_next, -- Not exactly sure how to deal with this but we should be able to manage it via explorer shim cache
    fs_stat         = M.fs_stat , -- Should map to netman.api.get_metadata

    fs_copyfile     = M.fs_copyfile, -- This is a cp command
    fs_mkdir        = M.fs_mkdir, -- should map to netman.api.write
    fs_rmdir        = M.fs_rmdir, -- should map to netman.api.delete
    fs_unlink       = M.fs_unlink, -- should map to netman.api.delete
    fs_rename       = M.fs_rename, -- should map to netman.api.rename
    getcwd          = M.getcwd, -- We need a way to track this, though I am not sold on the best way
    fs_chmod        = M.fs_chmod,
    fs_chown        = M.fs_chown,
    fs_closedir     = M.fs_closedir,
    fs_fchmod       = M.fs_fchmod,
    fs_fchown       = M.fs_fchown,
    fs_fdatasync    = M.fs_fdatasync,
    fs_fsync        = M.fs_fsync,
    fs_ftruncate    = M.fs_ftruncate,
    fs_futime       = M.fs_futime,
    fs_lchown       = M.fs_lchown,
    fs_link         = M.fs_link,
    fs_lstat        = M.fs_lstat,
    fs_lutime       = M.fs_lutime,
    fs_mkdtemp      = M.fs_mkdtemp,
    fs_mkstemp      = M.fs_mkstemp,
    fs_opendir      = M.fs_opendir,
    fs_readdir      = M.fs_readdir,
    fs_readlink     = M.fs_readlink,
    fs_sendfile     = M.fs_sendfile,
    fs_statfs       = M.fs_statfs,
    fs_symlink      = M.fs_symlink,
    fs_utime        = M.fs_utime,
    fs_write        = M.fs_write,
}

M._hidden_functions = {
    fs_fstat        = vim.loop.fs_fstat, -- Dont have a great way of dealing with this, likely via get_metadata
    fs_read         = vim.loop.fs_read, -- This is going to be a big pain in the ass :/
    fs_copyfile     = vim.loop.fs_copyfile, -- This is a cp command
    fs_open         = vim.loop.fs_open, -- should map (more or less) to netman.api.read
    fs_close        = vim.loop.fs_close, -- should map (more or less) to netman.api.unload
    fs_mkdir        = vim.loop.fs_mkdir, -- should map to netman.api.write
    fs_rmdir        = vim.loop.fs_rmdir, -- should map to netman.api.delete
    fs_unlink       = vim.loop.fs_unlink, -- should map to netman.api.delete
    fs_rename       = vim.loop.fs_rename, -- should map to netman.api.rename
    cwd             = vim.loop.cwd, -- We need a way to track this, though I am not sold on the best way
    getcwd          = vim.loop.getcwd, -- We need a way to track this, though I am not sold on the best way
    fs_realpath     = vim.loop.fs_realpath, -- should return the URI
    fs_scandir_next = vim.loop.fs_scandir_next, -- Not exactly sure how to deal with this but we should be able to manage it via explorer shim cache
    fs_scandir      = vim.loop.fs_scandir, -- Not exactly sure how to deal with this but we should be able to manage it via explorer shim cache
    fs_stat         = vim.loop.fs_stat , -- Should map to netman.api.get_metadata
    fs_access       = vim.loop.fs_access, -- should probably just return true?
    fs_chmod        = vim.loop.fs_chmod,
    fs_chown        = vim.loop.fs_chown,
    fs_closedir     = vim.loop.fs_closedir,
    fs_fchmod       = vim.loop.fs_fchmod,
    fs_fchown       = vim.loop.fs_fchown,
    fs_fdatasync    = vim.loop.fs_fdatasync,
    fs_fsync        = vim.loop.fs_fsync,
    fs_ftruncate    = vim.loop.fs_ftruncate,
    fs_futime       = vim.loop.fs_futime,
    fs_lchown       = vim.loop.fs_lchown,
    fs_link         = vim.loop.fs_link,
    fs_lstat        = vim.loop.fs_lstat,
    fs_lutime       = vim.loop.fs_lutime,
    fs_mkdtemp      = vim.loop.fs_mkdtemp,
    fs_mkstemp      = vim.loop.fs_mkstemp,
    fs_opendir      = vim.loop.fs_opendir,
    fs_readdir      = vim.loop.fs_readdir,
    fs_readlink     = vim.loop.fs_readlink,
    fs_sendfile     = vim.loop.fs_sendfile,
    fs_statfs       = vim.loop.fs_statfs,
    fs_symlink      = vim.loop.fs_symlink,
    fs_utime        = vim.loop.fs_utime,
    fs_write        = vim.loop.fs_write,
}

M._cachable_functions = {
    fs_access       = 1,
    -- fs_fstat        = 1, -- Caching fstat seems to break plenary?
    fs_realpath     = 1,
    fs_stat         = 1,
    fs_lstat        = 1,
    fs_readlink     = 1,
    fs_statfs       = 1,
}

function M:_init()
    if M._inited then return end

    for uv_func, override_func in pairs(M._override_functions) do
        local func = vim.loop[uv_func]
        vim.loop[uv_func] = function(...)
            local invalidate_indexes = {}
            for key, cache in pairs(M._lru_cache) do
                if cache[1] < os.clock() then
                    table.insert(invalidate_indexes, key)
                end
            end
            for _, key in ipairs(invalidate_indexes) do
                M._lru_cache[key] = nil
            end
            local func_hash = uv_func
            local _key = func_hash .. '('
            for i=1, select('#', ...) do
                _key = _key .. ',' .. tostring(select(i, ...))
            end
            _key = _key .. ')'
            local cachable = false
            if M._cachable_functions[uv_func] then
                cachable = true
                local cache = M._lru_cache[_key]
                if M._lru_cache[_key] then
                    log.trace("Returning cache result for " .. _key, cache[2])
                    return unpack(cache[2])
                end
            end 
            local caller = debug.getinfo(3, 'S')
            local call_func = func
            local found_match = false
            for overriden_caller_glob, _ in pairs(M._overriden_callers) do
                if caller and caller.source:find(overriden_caller_glob) then
                    call_func = override_func
                    found_match = true
                    break
                end
            end
            local results = {call_func(...)}
            log.trace({caller=caller, uv_func=uv_func, params=..., results=results})
            if cachable and found_match then
                M._lru_cache[_key] = {os.clock() + tick_limit, results}
            end
            return unpack(results)
        end
    end
    M._inited = true
end

M:_init()
return M