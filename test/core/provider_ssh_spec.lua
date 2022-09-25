_G._QUIET = true -- This makes bootstrap shut up
vim.g.netman_log_level = 0

local spy = require("luassert.spy")
local describe = require('busted').describe
local it = require('busted').it
local before_each = require("busted").before_each
local after_each = require("busted").after_each
local pending = require("busted").pending
describe("Netman Provider #ssh", function()
    describe("#init", function()
        before_each(function ()
            package.loaded['netman.providers.ssh'] = nil
        end)
        after_each(function ()
            package.loaded['netman.tools.shell'] = nil
        end)
        it("should complain if ssh isn't available for use", function()
            local shell = {
                new = function() return
                    {
                        run = function()
                            return {
                                stderr = "SUPER DUPER MEGA ERR",
                                exit_code = 9001,
                                stdout = "MUH DED"
                            }
                        end
                    }
                end
            }
            package.loaded['netman.tools.shell'] = shell
            assert.is_false(require("netman.providers.ssh").init(), "SSH failed to fail on failure to find ssh in path")
        end)
        it("should be happy if ssh is available for use", function ()
             local shell = {
                new = function() return
                    {
                        run = function()
                            return {
                                stderr = "",
                                exit_code = 0,
                                stdout = ""
                            }
                        end
                    }
                end
            }
            package.loaded['netman.tools.shell'] = shell
            assert.is_true(require("netman.providers.ssh").init(), "SSH failed to accept that ssh was found")
        end)
    end)
    describe("#_parse_uri", function() end)
        after_each(function()
            package.loaded['netman.providers.ssh'] = nil
        end)
        it("should fail if no protocol is provided", function()
            local uri = "://somehost/somepath"
            assert.is_nil(require("netman.providers.ssh").internal._parse_uri(uri), "SSH Failed to fail on missing protocol")
        end)
        it("should fail if an invalid protocol is provided", function()
            local uri = "someprotocol://somehost/somepath"
            assert.is_nil(require("netman.providers.ssh").internal._parse_uri(uri), "SSH Failed to fail on invalid protocol")
        end)
        it("should fail on invalid host provided", function()
            assert.is_nil(require("netman.providers.ssh").internal._parse_uri("sftp:///somepath/"), "SSH Failed to fail on missing hostname")
            assert.is_nil(require("netman.providers.ssh").internal._parse_uri("sftp:///somepath/somefile.txt"), "SSH Failed to fail on missing hostname")
        end)
        it("should fail on invalid path being provided", function()
            local error = "SSH failed to fail on invalid path"
            assert.is_nil(require("netman.providers.ssh").internal._parse_uri("sftp://somehost////somepath"), error)
            assert.is_nil(require("netman.providers.ssh").internal._parse_uri("sftp://somehost////somepath/somefile.txt"), error)
            assert.is_nil(require("netman.providers.ssh").internal._parse_uri("sftp://somehost//somepath"), error)
            assert.is_nil(require("netman.providers.ssh").internal._parse_uri("sftp://somehost//somepath/somefile.txt"), error)
        end)
        it("should not find a username", function()
            assert.is_nil(require("netman.providers.ssh").internal._parse_uri("sftp://somehost///somepath/somefile.txt").user, "SSH Found a username somehow")
        end)
        it("should find a username", function()
            assert.is_equal(require("netman.providers.ssh").internal._parse_uri("sftp://someuser@somehost///somepath/somefile.txt").user, "someuser", "SSH was not able to find a username")
        end)
        it("should not find a port", function ()
            assert.is_nil(require("netman.providers.ssh").internal._parse_uri("sftp://somehost///somepath/somefile.txt").port, "SSH Found a port somehow")
        end)
        it("should find a port", function ()
            assert.is_equal(require("netman.providers.ssh").internal._parse_uri("sftp://somehost:1111/somepath/somefile.txt").port, "1111", "SSH was not able to find the port")
        end)
        it("should find an absolute path", function()
            local _ = require("netman.providers.ssh").internal._parse_uri("sftp://somehost///somepath/somefile.txt")
            assert.is_equal("/somepath/somefile.txt", _.path, "SSH failed to find properly formatted absolute path")
            assert.is_false(_.is_relative)
        end)
        it("should find a relative path", function()
            local _ = require("netman.providers.ssh").internal._parse_uri("sftp://somehost/somepath/somefile.txt")
            assert.is_equal("/somepath/somefile.txt", _.path, "SSH failed to find properly formatted relative path")
            assert.is_true(_.is_relative, "SSH failed to properly identify a relative path")
        end)
        it("should find the user", function()
            assert.is_equal("someuser", require("netman.providers.ssh").internal._parse_uri("sftp://someuser@somehost/").user, "SSH failed to find properly formatted user")
        end)
        it("should find the port", function()
            assert.is_equal("1111", require("netman.providers.ssh").internal._parse_uri("sftp://somehost:1111/").port, "SSH failed to find properly formatted port")
        end)
        it('should identify a "link" (directory)', function()
            local directory_attr = require("netman.tools.options").api.ATTRIBUTES.DIRECTORY
            local explore_type   = require("netman.tools.options").api.READ_TYPE.EXPLORE
            local details        = require("netman.providers.ssh").internal._parse_uri("sftp://somehost/")
            assert.is_equal(directory_attr, details.file_type)
            assert.is_equal(explore_type, details.return_type)
        end)
        it('should identify a "destination" (file")', function ()
            local file_attr = require("netman.tools.options").api.ATTRIBUTES.FILE
            local file_type = require("netman.tools.options").api.READ_TYPE.FILE
            local details   = require("netman.providers.ssh").internal._parse_uri("sftp://somehost/somefile.txt")
            assert.is_equal(file_attr, details.file_type)
            assert.is_equal(file_type, details.return_type)
        end)
        it("should get the parent directory correct", function ()
            -- This seems wrong? These should return `/` instead of nothing?
            assert.is_equal(require("netman.providers.ssh").internal._parse_uri("sftp://somehost/").parent, "/", "SSH unable to match home_dir as parent")
            assert.is_equal(require("netman.providers.ssh").internal._parse_uri("sftp://somehost///").parent, "/", "SSH unable to match root as parent of itself")
            assert.is_equal(require("netman.providers.ssh").internal._parse_uri("sftp://somehost///somepath/somefile.txt").parent, "/somepath/", "SSH unable to match child in root as parent")
            assert.is_equal(require("netman.providers.ssh").internal._parse_uri("sftp://somehost/somepath").parent, "/", "SSH unable to match root as parent of child file")
            assert.is_equal(require("netman.providers.ssh").internal._parse_uri("sftp://somehost/somepath/somefile.txt").parent, "/somepath/", "SSH unable to match parent of child file")
        end)
        it("should generate a proper auth uri", function ()
            assert.is_equal(require("netman.providers.ssh").internal._parse_uri("sftp://somehost/").auth_uri, "somehost", "SSH did not create a valid username-less auth uri")
            assert.is_equal(require("netman.providers.ssh").internal._parse_uri("sftp://somehost:1111/").auth_uri, "somehost", "SSH did not ignore the port in the connection details for the auth uri")
            assert.is_equal(require("netman.providers.ssh").internal._parse_uri("sftp://user@somehost/").auth_uri, "user@somehost", "SSH did not include the username in the auth uri")
        end)
    end)
    describe("#_process_find_results", function()
        it("should properly read a valid find result from a file", function()
            local mode = "81ed"
            local blocks = '0'
            local blksize = '512'
            local mtime_sec = '1662860937'
            local user = 'root'
            local group = 'root'
            local inode = '1092025921'
            local permissions = '755'
            local size = '0'
            local type = 'regular file'
            local name = 'somefilename'
            local input_result = string.format("MODE=%s,BLOCKS=%s,BLKSIZE=%s,MTIME_SEC=%s,USER=%s,GROUP=%s,INODE=%s,PERMISSIONS=%s,SIZE=%s,TYPE=%s,NAME=%s", mode, blocks, blksize, mtime_sec, user, group, inode, permissions, size, type, name)
            local result = require("netman.providers.ssh").internal._process_find_result(input_result)
            assert.is_equal(result.TYPE, 'file', "SSH failed to properly identify file type")
            assert.is_equal(result.FIELD_TYPE, require("netman.tools.options").explorer.METADATA.DESTINATION, "SSH failed to properly identify field type")
            assert.is_equal(result.NAME, name, "SSH failed to properly identify file name")
            assert.is_equal(result.ABSOLUTE_PATH, name, "SSH failed to properly identify path to file")
            assert.is_equal(result.MODE, mode, "SSH failed to properly identify mode of file")
            assert.is_equal(result.BLOCKS, blocks, "SSH failed to properly identify blocks of file")
            assert.is_equal(result.BLKSIZE, blksize, "SSH failed to properly identify block size of file")
            assert.is_equal(result.MTIME_SEC, mtime_sec, "SSH failed to properly identify mtime seconds of file")
            assert.is_equal(result.USER, user, "SSH failed to properly identify the owner of file")
            assert.is_equal(result.GROUP, group, "SSH failed to properly identify the owning group of file")
            assert.is_equal(result.INODE, inode, "SSH failed to fine file's inode")
            assert.is_equal(result.PERMISSIONS, permissions, "SSH failed to identify file's permissions")
            assert.is_equal(result.SIZE, size, "SSH failed to identify size of file")
        end)
        it("should properly read a valid find result from an empty file", function()
            local mode = "81ed"
            local blocks = '0'
            local blksize = '512'
            local mtime_sec = '1662860937'
            local user = 'root'
            local group = 'root'
            local inode = '1092025921'
            local permissions = '755'
            local size = '0'
            local type = 'regular empty file'
            local name = 'somefilename'
            local input_result = string.format("MODE=%s,BLOCKS=%s,BLKSIZE=%s,MTIME_SEC=%s,USER=%s,GROUP=%s,INODE=%s,PERMISSIONS=%s,SIZE=%s,TYPE=%s,NAME=%s", mode, blocks, blksize, mtime_sec, user, group, inode, permissions, size, type, name)
            local result = require("netman.providers.ssh").internal._process_find_result(input_result)
            assert.is_equal(result.TYPE, 'file', "SSH failed to properly identify file type")
            assert.is_equal(result.FIELD_TYPE, require("netman.tools.options").explorer.METADATA.DESTINATION, "SSH failed to properly identify field type")
            assert.is_equal(result.NAME, name, "SSH failed to properly identify file name")
            assert.is_equal(result.ABSOLUTE_PATH, name, "SSH failed to properly identify path to file")
            assert.is_equal(result.MODE, mode, "SSH failed to properly identify mode of file")
            assert.is_equal(result.BLOCKS, blocks, "SSH failed to properly identify blocks of file")
            assert.is_equal(result.BLKSIZE, blksize, "SSH failed to properly identify block size of file")
            assert.is_equal(result.MTIME_SEC, mtime_sec, "SSH failed to properly identify mtime seconds of file")
            assert.is_equal(result.USER, user, "SSH failed to properly identify the owner of file")
            assert.is_equal(result.GROUP, group, "SSH failed to properly identify the owning group of file")
            assert.is_equal(result.INODE, inode, "SSH failed to fine file's inode")
            assert.is_equal(result.PERMISSIONS, permissions, "SSH failed to identify file's permissions")
            assert.is_equal(result.SIZE, size, "SSH failed to identify size of file")
        end)
        it("should properly read a valid find result from a directory", function()
            local mode = "81ed"
            local blocks = '0'
            local blksize = '512'
            local mtime_sec = '1662860937'
            local user = 'root'
            local group = 'root'
            local inode = '1092025921'
            local permissions = '755'
            local size = '0'
            local type = 'directory'
            local name = 'somefilename'
            local input_result = string.format("MODE=%s,BLOCKS=%s,BLKSIZE=%s,MTIME_SEC=%s,USER=%s,GROUP=%s,INODE=%s,PERMISSIONS=%s,SIZE=%s,TYPE=%s,NAME=%s", mode, blocks, blksize, mtime_sec, user, group, inode, permissions, size, type, name)
            local result = require("netman.providers.ssh").internal._process_find_result(input_result)
            assert.is_equal(result.TYPE, 'directory', "SSH failed to properly identify file type")
            assert.is_equal(result.FIELD_TYPE, require("netman.tools.options").explorer.METADATA.LINK, "SSH failed to properly identify field type")
            assert.is_equal(result.NAME, name, "SSH failed to properly identify file name")
            assert.is_equal(result.ABSOLUTE_PATH, name, "SSH failed to properly identify path to file")
            assert.is_equal(result.MODE, mode, "SSH failed to properly identify mode of file")
            assert.is_equal(result.BLOCKS, blocks, "SSH failed to properly identify blocks of file")
            assert.is_equal(result.BLKSIZE, blksize, "SSH failed to properly identify block size of file")
            assert.is_equal(result.MTIME_SEC, mtime_sec, "SSH failed to properly identify mtime seconds of file")
            assert.is_equal(result.USER, user, "SSH failed to properly identify the owner of file")
            assert.is_equal(result.GROUP, group, "SSH failed to properly identify the owning group of file")
            assert.is_equal(result.INODE, inode, "SSH failed to fine file's inode")
            assert.is_equal(result.PERMISSIONS, permissions, "SSH failed to identify file's permissions")
            assert.is_equal(result.SIZE, size, "SSH failed to identify size of file")
        end)
        it("should properly read a valid find result with absolute path name", function()
            local mode = "81ed"
            local blocks = '0'
            local blksize = '512'
            local mtime_sec = '1662860937'
            local user = 'root'
            local group = 'root'
            local inode = '1092025921'
            local permissions = '755'
            local size = '0'
            local type = 'directory'
            local name = 'somefilename'
            local path = string.format("/somepath/%s", name)
            local input_result = string.format("MODE=%s,BLOCKS=%s,BLKSIZE=%s,MTIME_SEC=%s,USER=%s,GROUP=%s,INODE=%s,PERMISSIONS=%s,SIZE=%s,TYPE=%s,NAME=%s", mode, blocks, blksize, mtime_sec, user, group, inode, permissions, size, type, path)
            local result = require("netman.providers.ssh").internal._process_find_result(input_result)
            assert.is_equal(result.TYPE, 'directory', "SSH failed to properly identify file type")
            assert.is_equal(result.FIELD_TYPE, require("netman.tools.options").explorer.METADATA.LINK, "SSH failed to properly identify field type")
            assert.is_equal(result.NAME, name, "SSH failed to properly identify file name")
            assert.is_equal(result.ABSOLUTE_PATH, path, "SSH failed to properly identify path to file")
            assert.is_equal(result.MODE, mode, "SSH failed to properly identify mode of file")
            assert.is_equal(result.BLOCKS, blocks, "SSH failed to properly identify blocks of file")
            assert.is_equal(result.BLKSIZE, blksize, "SSH failed to properly identify block size of file")
            assert.is_equal(result.MTIME_SEC, mtime_sec, "SSH failed to properly identify mtime seconds of file")
            assert.is_equal(result.USER, user, "SSH failed to properly identify the owner of file")
            assert.is_equal(result.GROUP, group, "SSH failed to properly identify the owning group of file")
            assert.is_equal(result.INODE, inode, "SSH failed to fine file's inode")
            assert.is_equal(result.PERMISSIONS, permissions, "SSH failed to identify file's permissions")
            assert.is_equal(result.SIZE, size, "SSH failed to identify size of file")
        end)
    describe("#_validate_cache", function()
        after_each(function()
            package.loaded['netman.providers.ssh'] = nil
        end)
        it("should quick escape if there is already a cached result for the uri provided", function()
            local cache = require("netman.tools.cache"):new()
            cache:add_item('sftp://somehost/somefile.txt', {
                cache = "CACHE",
                details = "DETAILS"
            })
            local results_cache, results_details = require("netman.providers.ssh").internal._validate_cache(cache, "sftp://somehost/somefile.txt")
            assert.is_equal(results_cache, "CACHE", "SSH did not return the right cached  cache item")
            assert.is_equal(results_details, "DETAILS", "SSH did not return the right cached detail item")
        end)
        it("should not do anything if there is an invalid uri", function ()
            require("netman.providers.ssh").internal._parse_uri = function() end
            local cache = require("netman.tools.cache"):new()
            assert.is_nil(require("netman.providers.ssh").internal._validate_cache(cache, ""), "SSH failed to properly die on invalid URI")
        end)
        it("should create the cache for the uri", function()
            local cache = require("netman.tools.cache"):new()
            require("netman.providers.ssh").internal._parse_uri = function()
                return {
                    host = ""
                }
            end
            require("netman.providers.ssh").internal._validate_cache(cache, "")
            local cached_item = cache:get_item("")
            assert.is_not_nil(cached_item, "SSH did not create a new cache for a new URI")
            assert.is_not_nil(cached_item.cache, "SSH did not associate a proper cache item with the provided URI")
            assert.is_not_nil(cached_item.details, "SSH did not associate the parsed URI details with the provided URI")
            cached_item = cached_item.cache
            assert.is_not_nil(cached_item:get_item("files"), "SSH did not create an entry in cache for files")
            assert.is_not_nil(cached_item:get_item("file_metadata"), "SSH did not create an entry in cache for metadata")
        end)
    end)
    describe("#_read_file #debug", function()
    end)
    describe("#_read_directory", function() end)
    describe("#_write_file", function() end)
    describe("#_create_directory", function() end)
end)
