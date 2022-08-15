local CACHE = require('netman.tools.cache')
local log = require('netman.tools.utils').log
local utils = require('netman.tools.utils')
local METADATA_FLAGS = require("netman.tools.options").explorer.METADATA
-- TODO: Mike: Figure out how to collalesce multiple identical calls into one to prevent
-- call flooding

local STAT_KEYS = {
    [METADATA_FLAGS.DEV] = 'dev',
    [METADATA_FLAGS.MODE] = 'mode',
    [METADATA_FLAGS.NLINK] = 'nlink',
    [METADATA_FLAGS.UID] = 'uid',
    [METADATA_FLAGS.GID] = 'gid',
    [METADATA_FLAGS.RDEV] = 'rdev',
    [METADATA_FLAGS.INODE] = 'ino',
    [METADATA_FLAGS.SIZE] = 'size',
    [METADATA_FLAGS.MODE] = 'mode',
    [METADATA_FLAGS.BLKSIZE] = 'blksize',
    [METADATA_FLAGS.BLOCKS] = 'blocks',
    [METADATA_FLAGS.FLAGS] = 'flags',
    [METADATA_FLAGS.GEN] = 'gen',
    [METADATA_FLAGS.ATIME_SEC] = 'atime_sec',
    [METADATA_FLAGS.ATIME_NSEC] = 'atime_nsec',
    [METADATA_FLAGS.MTIME_SEC] = 'mtime_sec',
    [METADATA_FLAGS.MTIME_NSEC] = 'mtime_nsec',
    [METADATA_FLAGS.CTIME_SEC] = 'ctime_sec',
    [METADATA_FLAGS.CTIME_NSEC] = 'ctime_nsec',
    [METADATA_FLAGS.BTIME_SEC] = 'btime_sec',
    [METADATA_FLAGS.BTIME_NSEC] = 'btime_nsec',
    [METADATA_FLAGS.TYPE] = 'type',
    [METADATA_FLAGS.DEV] = 'dev',
    [METADATA_FLAGS.PERMISSIONS] = 'permisions',
}

local META_FLAGS = {}
if #META_FLAGS == 0 then
    for key, _ in pairs(STAT_KEYS) do
        table.insert(META_FLAGS, key)
    end
end

local META_FUNCS = {
    blksize = function(metadata) return tonumber(metadata.blksize) end,
    mode = function(metadata) if metadata.mode then return tonumber(metadata.mode, 16) else return nil end end,
    size = function(metadata) return tonumber(metadata.size) end,
    atime = function(metadata) return {sec = tonumber(metadata.atime_sec), nsec = tonumber(metadata.atime_nsec)} end,
    mtime = function(metadata) return {sec = tonumber(metadata.mtime_sec), nsec = tonumber(metadata.mtime_nsec)} end,
    ctime = function(metadata) return {sec = tonumber(metadata.ctime_sec), nsec = tonumber(metadata.ctime_nsec)} end,
    birthtime = function(metadata) return {sec = tonumber(metadata.btime_sec), nsec = tonumber(metadata.btime_nsec) } end,
    permissions = function(metadata) return tonumber(metadata.permissions) end,
}

local M = {}
local libruv = {}
-- Setting up the libruv object

libruv.__fs_index = -1
libruv.__id_map = CACHE:new()
libruv.__path_map = CACHE:new()
libruv.__rcwd = nil

M.__inited = false
M.__cache = nil
M.__rcwd = nil

M.protocol_patterns = require('netman.tools.options').protocol.EXPLORE
M.version = 0.1

local stat_conversion = function(pre_metadata_table)
    local cache = {}
    local converted_key = nil
    for key, value in pairs(pre_metadata_table) do
        converted_key = STAT_KEYS[key]
        if converted_key then
            cache[converted_key] = value
        end
    end
    for flag, func in pairs(META_FUNCS) do
        cache[flag] = func(cache)
    end
    return cache
end

function libruv.fs_readlink(path, callback)
    local mapped_path = M.__cache:get_item('remote_to_local_map'):get_item(path) or libruv.__fs_readlink(path)
    if callback then
        callback(nil, mapped_path)
        return
    else
        return mapped_path
    end
end

function libruv.fs_realpath(path, callback)
    local mapped_path = M.__cache:get_item('remote_to_local_map'):get_item(path) or libruv.__fs_realpath(path)
    if callback then
        callback(nil, mapped_path)
        return
    else
        return mapped_path
    local _clean_path = clean_path(path)
    if M.__cache:get_item('local_to_remote_map'):get_item(_clean_path) then
        if callback then
            callback(nil, _clean_path)
            return
        else
            return _clean_path
        end
    end
    return libruv.__fs_realpath(path, callback)
end

function libruv.fs_access(path, mode, callback)
    if
        M.__cache:get_item('local_to_remote_map'):get_item(path)
        or M.__cache:get_item('remote_to_local_map'):get_item(path)
    then
        if callback then callback(true) else return true end
    end
    return libruv.__fs_access(path, mode, callback)
end

function libruv.fs_open(path, flags, mode, callback, is_remote)
    local file_id = libruv.__path_map:get_item(path)
    if file_id then
        if callback then
            callback(file_id)
            return
        else
            return file_id
        end
    end
    -- This path match is actually wrong because it means that opening a local file 
    -- will still be considered remote and __das_bad__
    if is_remote or require("netman.api").is_path_netman_uri(path) then
        libruv.__fs_index = libruv.__fs_index - 1
        file_id = libruv.__fs_index
        libruv.__id_map:add_item(file_id, path)
        libruv.__path_map:add_item(path, file_id)
        return file_id
    else
        return libruv.__fs_open(path, flags, mode, callback)
    end
end

function libruv.fs_close(file_id, callback)
    if not libruv.__id_map:get_item(file_id) then
        return libruv.__fs_close(file_id, callback)
    end
    local mapped_path = libruv.__id_map:get_item(file_id)
    if mapped_path then
        libruv.__path_map:remove_item(mapped_path)
    end
    libruv.__id_map:remove_item(file_id)
    if callback then
        callback(nil, true)
    end
end

-- TODO: Mike: Implement entries
function libruv.fs_opendir(path, callback, entries)
    local file_id = libruv.__path_map:get_item(path)
    if file_id then
        if callback then
            callback(nil, file_id)
            return
        else
           return file_id
       end
    end
    if require("netman.api").is_path_netman_uri(path) then
        file_id = libruv.fs_scandir(path)
        if callback then
            callback(nil, file_id)
            return
        else
            return file_id
        end
    else
        return libruv.__fs_opendir(path, callback, entries)
    end
end

function libruv.fs_stat(path, callback)
    path = clean_path(path)
    local mapped_path = M.__cache:get_item('local_to_remote_map'):get_item(path)
    if mapped_path then path = mapped_path.path end
    if not require("netman.api").is_path_netman_uri(path) then
        return libruv.__fs_stat(path, callback)
    end
    local cache = M.__cache:get_item('file_metadata'):get_item(path)
    if cache then
        if callback then
            callback(nil, cache)
            return
        end
        return cache
    end
    local _pre_cache = require("netman.api").get_metadata(path, META_FLAGS)
    cache = stat_conversion(_pre_cache)
    M.__cache:get_item('file_metadata'):add_item(path, cache)
    return cache
end

function libruv.fs_fstat(file_id, callback)
    if not libruv.__id_map:get_item(file_id) then
        return libruv.__fs_fstat(file_id, callback)
    end
    return libruv.fs_stat(libruv.__id_map(file_id), callback)
end

function libruv.fs_readdir(dir, callback)
    if not libruv.__id_map:get_item(dir) then
        return libruv.__fs_readdir(dir, callback)
    end
    local entries = nil
    local count = 0
    local keep_running = true
    local contents = {}
    while keep_running do
        local entry = libruv.fs_scandir_next(dir)
        if not entry or (entries and count >= entries) then
            keep_running = false
        else
            table.insert(contents, {name=entry[1], type=entry[2]})
        end
    end
    if callback then
        callback(nil, contents)
        return
    else
        return contents
    end
end

function libruv.fs_closedir(dir, callback)
    if not libruv.__id_map:get_item(dir) then
        return libruv.__fs_closedir(dir, callback)
    end
    libruv.fs_close(dir)
    if callback then
        callback(nil, true)
        return
    end
end

function libruv.fs_scandir(path, callback)
    log.trace("Scanning " .. tostring(path))
    local mapped_path_details = M.__cache:get_item('local_to_remote_map'):get_item(path)
    if not mapped_path_details then
        log.trace("No mapped directory found for " .. tostring(path))
        return libruv.__fs_scandir(path, callback)
    end
    local mapped_path = mapped_path_details.path
    if mapped_path_details.type == 'directory' and mapped_path:sub(-1, -1) ~= '/' then
        mapped_path = mapped_path .. '/'
    end
    local file_id = libruv.fs_open(mapped_path)
    local scandir_cache = M.__cache:get_item('scandir_cache')[file_id]
    if not scandir_cache then
        scandir_cache = {}
        scandir_cache = require('netman.api').read(mapped_path)
        M.__cache:get_item('scandir_cache')[file_id] = scandir_cache
    end
    if not scandir_cache or not scandir_cache.parent then
        log.warn("Unable to get details for " .. path)
        log.info("Falling back to system call")
        return libruv.__fs_scandir(path, callback)
    end
    local parent_details = scandir_cache.parent
    M.rcd(path, mapped_path)
    local local_to_remote_map = M.__cache:get_item('local_to_remote_map')
    local remote_to_local_map = M.__cache:get_item('remote_to_local_map')
    local files_metadata      = M.__cache:get_item('file_metadata')
    local scandir_tmp         = M.__cache:get_item('scandir_tmp')[file_id]
    if not scandir_tmp then
        scandir_tmp = {}
        M.__cache:get_item('scandir_tmp')[file_id] = scandir_tmp
    end
    local_to_remote_map:add_item('..', {path=parent_details.remote, type='directory'})
    local_to_remote_map:add_item('../', {path=parent_details.remote, type='directory'})
    local_to_remote_map:add_item(parent_details.display, {path=parent_details.remote, type='directory'})
    for _, item in ipairs(scandir_cache.contents) do
        table.insert(scandir_tmp, item)
        if item['METADATA'] then files_metadata:add_item(item['URI'], stat_conversion(item['METADATA'])) end
        -- This seems to be the wrong type...?
        local i = {path = item['URI'], type=item['TYPE']}
        local_to_remote_map:add_item(item['NAME'], i)
        local_to_remote_map:add_item(item['ABSOLUTE_PATH'], i)
        remote_to_local_map:add_item(item['URI'], item['NAME'])
    end
    if callback then callback(nil, file_id) else return file_id end
end

function libruv.fs_scandir_next(file_id)
    if not libruv.__id_map:get_item(file_id) then
        -- Not our file id to handle
        return libruv.__fs_scandir_next(file_id)
    end
    M.__cache:validate()
    local _cached_files = M.__cache:get_item('scandir_tmp')[file_id]
    if not _cached_files then return nil end
    local _, return_item = next(_cached_files)
    if not return_item then return nil end
    table.remove(M.__cache:get_item('scandir_tmp')[file_id], 1)
    return return_item['NAME'], return_item['FIELD_TYPE']
end

function libruv.cwd()
    local cwd = nil
    if is_caller_explorer() then
        if libruv.__rcwd then
            cwd = libruv.__rcwd
        else
            -- TODO: (Mike): Do this
            log.warn("It looks like a call for cwd was made on a remote buffer from which is not a registered File Explorer...")
            cwd = libruv.__cwd()
        end
    else
        cwd = libruv.__cwd()
    end
    log.trace("Returning cwd " .. tostring(cwd) .. " for caller " .. utils.get_calling_source(), {cwd=cwd, rcwd=libruv.__rcwd})
    return cwd
end

function libruv.init()
    if libruv.__inited then return end
    libruv.__inited = true
    libruv.__rcwd = nil

    log.info("Backing up vim.loop file system functions")
    libruv.__fs_scandir = vim.loop.fs_scandir
    libruv.__fs_scandir_next = vim.loop.fs_scandir_next
    libruv.__fs_open = vim.loop.fs_open
    libruv.__fs_close = vim.loop.fs_close
    libruv.__fs_access = vim.loop.fs_access
    libruv.__fs_realpath = vim.loop.fs_realpath
    libruv.__fs_readlink = vim.loop.fs_readlink
    libruv.__fs_opendir  = vim.loop.fs_opendir
    libruv.__fs_readdir = vim.loop.fs_readdir
    libruv.__fs_closedir = vim.loop.fs_closedir
    libruv.__fs_stat = vim.loop.fs_stat
    libruv.__fs_fstat = vim.loop.fs_fstat
    libruv.__cwd = vim.loop.cwd
    libruv.__getcwd = vim.fn.getcwd

    log.info("Overriding vim.loop file system functions")
    vim.loop.fs_scandir = libruv.fs_scandir
    vim.loop.fs_scandir_next = libruv.fs_scandir_next
    vim.loop.fs_open = libruv.fs_open
    vim.loop.fs_close = libruv.fs_close
    vim.loop.fs_access = libruv.fs_access
    vim.loop.fs_realpath = libruv.fs_realpath
    vim.loop.fs_readlink = libruv.fs_readlink
    vim.loop.fs_opendir = libruv.fs_opendir
    vim.loop.fs_readdir = libruv.fs_readdir
    vim.loop.fs_closedir = libruv.fs_closedir
    vim.loop.fs_stat = libruv.fs_stat
    vim.loop.fs_fstat = libruv.fs_fstat
    vim.loop.cwd = libruv.cwd
    vim.fn.getcwd = vim.loop.cwd
end

function M.rcd(new_cwd, r_cwd)
    if new_cwd:len() > 2 and new_cwd:match('/$') then
        new_cwd = new_cwd:sub(1,-2)
    end
    -- Consider if we want this returning this or the remote directory?
    libruv.__rcwd = new_cwd
    if r_cwd then
        M.__cache:get_item('local_to_remote_map'):add_item(new_cwd, {path=r_cwd, type='directory'})
        M.__cache:get_item('remote_to_local_map'):add_item(r_cwd, new_cwd)
        M.__cache:get_item('local_to_remote_map'):add_item('.', {path=r_cwd, type='directory'})
        M.__cache:get_item('local_to_remote_map'):add_item('./', {path=r_cwd, type='directory'})
    end
end

function M.is_path_local_to_remote_map(path)
    local mapped_path = M.__cache:get_item('local_to_remote_map'):get_item(path)
    if mapped_path then
        return mapped_path.path, true
    else
        return path, false
    end
end

function M.is_path_remote_to_local_map(path)
    local mapped_path = M.__cache:get_item('remote_to_local_map'):get_item(path)
    if mapped_path then
        return mapped_path, true
    else
        return path, false
    end
end

function M.change_buffer(new_current_buffer)
    local parent = M.__cache:get_item('rcwd_map')[new_current_buffer]
    local mapped_parent = nil
    if parent then
        mapped_parent = M.__cache:get_item('local_to_remote_map'):get_item(parent)
        M.rcd(parent, mapped_parent.path)
    end
end

function M.clear_rcwd()
    libruv.__rcwd = nil
end

--- Clears out all stored data associated with the current browsing session
--- Note: Does _not_ clear out the remote current working directory
function M.clear()
    M.__cache:get_item('scandir_cache'):clear()
    -- M.__cache:get_item('local_to_remote_map'):clear()
    -- M.__cache:get_item('remote_to_local_map'):clear()
    M.__cache:add_item('scandir_tmp', {})
end

function M.init()
    if M.__inited then return end
    M.__inited = true
    M.__cache = CACHE:new()
    M.__cache:add_item('scandir_cache', CACHE:new(CACHE.SECOND * 5))
    M.__cache:add_item('scandir_tmp', {})
    M.__cache:add_item('local_to_remote_map', CACHE:new())
    M.__cache:add_item('remote_to_local_map', CACHE:new())
    M.__cache:add_item('rcwd_map', {})
    M.__cache:add_item('file_metadata', CACHE:new(CACHE.SECOND * 2))
    libruv.init()
    -- M.__cache:add_item('metadata_cache', CACHE:new())
end

M:init()
return M
