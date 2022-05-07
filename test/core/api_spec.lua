local mock = require('luassert.mock')
local stub = require('luassert.stub')
local spy = require('luassert.spy')
local netman_options = require("netman.options")

-- TODO(Mike): Figure out how to Mock "vim." functions
-- so that we can use vanilla busted without needing
-- neovim for basic implementation unit testing

describe("Netman Core #netman-core", function()
    -- I am not super fond of this, but it is how the busted framework
    -- says to handle unit testing of internal methods
    -- http://olivinelabs.com/busted/#private
    _G._UNIT_TESTING = true
    
    _G.mock_provider_path = "mock_provider"
    -- Create dummy provider for junk uri.
    -- Something like junk://file123
    _G.mock_uri1 = "junk1://junk123"
    _G.mock_uri2 = "junk2://junk123"
    _G.invalid_mock_uri = "someuseless_uri://file"
    _G.dummy_stream = { 'Some complete garbage' ,'literally useless junk' }
    _G.dummy_file = "non-existent-file.txt"
    vim.g.netman_log_level = 1
    _G.api = require('netman.api')
    _G.mock_provider1 = {
        name = 'mock_provider1',
        protocol_patterns = {'junk1'},
        version = '0.0',
        _provider_path = _G.mock_provider_path .. "1",
        read = function() end,
        write = function() end,
        delete = function() end,
        parse_uri = function() end,
        get_metadata = function() end,
        init = function() return true end
    }
    _G.mock_provider2 = {
        name = 'mock_provider2',
        protocol_patterns = {'junk2'},
        version = '0.0',
        _provider_path = _G.mock_provider_path .. "2",
        read = function() end,
        write = function() end,
        delete = function() end,
        parse_uri = function() end,
        get_metadata = function() end,
        init = function() return true end
    }
    package.loaded[_G.mock_provider1.name] =_G.mock_provider1
    package.loaded[_G.mock_provider2.name] =_G.mock_provider1

    describe("read", function()
        before_each(function()
            _G.api._providers[_G.mock_provider1.protocol_patterns[1]] = _G.mock_provider1
            _G.api._buffer_provider_cache["" .. 1] = nil
            _G.cache_func = _G.mock_provider1.read
            _G.api._unclaimed_id_table = {}
        end)
        after_each(function()
            _G.mock_provider1.read = _G.cache_func
            _G.cache_func = nil
            _G.api._providers[_G.mock_provider1.protocol_patterns[1]] = nil
            _G.api._buffer_provider_cache["" .. 1] = nil
            _G.api._unclaimed_id_table = {}
        end)
        it("should attempt to read from mock provider", function()
            local s = spy.on(_G.mock_provider1, 'read')
            _G.api:read(1, _G.mock_uri1)
            assert.spy(s).was_called()
            _G.mock_provider1.read:revert()
        end)
        it("should not attempt to read from mock provider", function()
            _G.api._providers[_G.mock_provider1.protocol_patterns[1]] = nil
            local s = spy.on(_G.mock_provider1, 'read')
            assert.has_error(function() _G.api:read(1, _G.mock_uri1) end, '"Error parsing path: ' .. _G.mock_uri1 .. ' -- Unable to establish provider"', "Netman loaded provider somehow!")
            assert.spy(s).was_not_called()
            _G.mock_provider1.read:revert()
        end)
        pending("should provide cache provider details for existing mock uri")
        it("should complain but attempt to fix return file not being a table", function()
            _G.mock_provider1.read = function()
                return _G.dummy_file, _G.api.READ_TYPE.FILE
            end
            assert.has_no.errors(function() _G.api:read(1, _G.mock_uri1) end, "Failed to self correct string file return as table")
        end)
        it("should complain but attempt to fix return stream not being a table", function()
            local read_cache = _G.mock_provider1.read
            _G.mock_provider1.read = function()
                return _G.dummy_file, _G.api.READ_TYPE.STREAM
            end
            assert.has_no.errors(function() _G.api:read(1, _G.mock_uri1) end, "Failed to self correct string stream return as table")
            _G.mock_provider1.read = read_cache
            read_cache = nil
        end)
        it("return command should be for a file read type", function()
            _G.mock_provider1.read = function()
                return {origin_path=_G.dummy_file, local_path=_G.dummy_file}, netman_options.api.READ_TYPE.FILE
            end
            assert.is_equal(_G.api:read(1, _G.mock_uri1):match('^read %+%+edit'), 'read ++edit', "Failed to generate read to buffer command")
        end)
       it("read should return nil and accept nil read type", function()
            assert.is_nil(_G.api:read(1, _G.mock_uri1), "Read Command didn't return nil on nil read type!")
        end)
        it("should create an append command (append!) followed by the input stream", function()
            assert.is_equal(_G.api._read_as_stream(_G.dummy_stream), "0append! " .. table.concat(_G.dummy_stream, '\n'), "Failed to create append command")
        end)
        it("should create a read command (read ++edit) followed by the local file", function()
            assert.is_equal(_G.api._read_as_file({origin_path=_G.dummy_file,local_path=_G.dummy_file}):match("^read %+%+edit"), "read ++edit", "Failed to create append command")
        end)
        it("should remove invalid entries from _read_as_explore", function()
            local invalid_key1 = "INVALID_KEY1"
            local invalid_key2 = "INVALID_KEY2"
            local valid_key1 = netman_options.explorer.METADATA.NAME
            local required_key1 = netman_options.explorer.FIELDS.FIELD_TYPE
            local invalid_object = {}
            invalid_object[invalid_key1]  = "something cool1"
            invalid_object[invalid_key2]  = "something cool2"
            invalid_object[valid_key1]    = "valid key1"
            invalid_object[required_key1] = "required key1"
            local valid_object = {}
            valid_object[valid_key1]    = "valid key1"
            valid_object[required_key1] = "required key1"
            local sanitized_details = _G.api._read_as_explore({parent=1, remote_files = invalid_object})
            assert.is_true(table.concat(sanitized_details.details) == table.concat(valid_object), "Failed to return correct formatted explore object")
            assert.is_equal(sanitized_details.parent, 1, "Failed to return inputted parent!")
        end)
        describe("_get_provider_for_path", function()
            after_each(function()
                _G.api._providers[_G.mock_provider1.protocol_patterns[1]] = nil
            end)
            it("should return the mock provider for mock uri", function()
                _G.api._providers[_G.mock_provider1.protocol_patterns[1]] = _G.mock_provider1
                local provider = _G.api._get_provider_for_path(_G.mock_uri1)
                assert.is_not_nil(provider, "Failed to load any provider!")
                assert.is_equal(provider.name, _G.mock_provider1.name, "Returned incorrect provider!")
            end)
            it("should not return the mock provider for other uri", function()
                local provider = nil
                assert.has_error(function()
                    _G.api._get_provider_for_path(_G.invalid_mock_uri)
                end, "\"Error parsing path: " .. _G.invalid_mock_uri .. " -- Unable to establish provider\"", "Failed to throw error for invalid provider!")
                assert.is_nil(provider, "Associated mock uri with invalid uri")
            end)
        end)
    end)

    describe("write", function()
        before_each(function()
            _G.api._providers[_G.mock_provider1.protocol_patterns[1]] = _G.mock_provider1
            _G.api._buffer_provider_cache["" .. 1] = nil
            _G.cache_func = _G.mock_provider1.write
        end)
        after_each(function()
            _G.mock_provider1.write = _G.cache_func
            _G.cache_func = nil
            _G.api._buffer_provider_cache["" .. 1] = nil
            _G.api._providers[_G.mock_provider1.protocol_patterns[1]] = nil
        end)
        it("should attempt to write to mock uri", function()
            local s = spy.on(_G.mock_provider1, 'write')
            _G.api:write(1, _G.mock_uri1)
            assert.spy(s).was_called()
            _G.mock_provider1.write:revert()
        end)
        pending("should not attempt to write to mock uri")
    end)

    describe("delete", function()
        before_each(function()
            _G.api._providers[_G.mock_provider1.protocol_patterns[1]] = _G.mock_provider1
            _G.api._buffer_provider_cache["" .. 1] = nil
            _G.cache_func = _G.mock_provider1.delete
        end)
        after_each(function()
            _G.mock_provider1.delete = _G.cache_func
            _G.cache_func = nil
            _G.api._providers[_G.mock_provider1.protocol_patterns[1]] = nil
            _G.api._buffer_provider_cache["" .. 1] = nil
        end)
        it("should attempt to delete to mock uri", function()
            local s = spy.on(_G.mock_provider1, 'delete')
            _G.api:delete(_G.mock_uri1)
            assert.spy(s).was_called()
            _G.mock_provider1.delete:revert()
        end)
        pending("should not attempt to delete to mock uri")
    end)

    describe("init", function()
        before_each(function()
            _G.cache_func = _G.api.init
            _G.api._initialized = false
            -- TODO(Mike): Figure out how to clear this out without using vim
            vim.api.nvim_command('comclear')
        end)
        after_each(function()
            _G.api.init = _G.cache_func
            _G.cache_func = nil
            _G.api._initialized = false
            -- TODO(Mike): Figure out how to clear this out without using vim
            vim.api.nvim_command('comclear')
        end)
        it("should load the core providers", function()
            local s = spy.on(_G.api, 'load_provider')
            _G.api:init({_G.mock_provider1.name})
            assert.spy(s).was_called()
            _G.api.load_provider:revert()
        end)
    end)

    describe("buffer_cache_object", function()
        before_each(function()
            _G.api._providers[_G.mock_provider1.protocol_patterns[1]] = _G.mock_provider1
            _G.api._providers[_G.mock_provider2.protocol_patterns[1]] = _G.mock_provider2
            _G.cache_buf = _G.api._buffer_provider_cache["" .. 1]
            _G.api._buffer_provider_cache["" .. 1] = {}
            _G.api._buffer_provider_cache["" .. 1][_G.mock_provider1.protocol_patterns[1]] = {
                provider = _G.mock_provider1
            }
            _G.api._buffer_provider_cache["" .. 1][_G.mock_provider2.protocol_patterns[1]] = {
                provider = _G.mock_provider2
            }
        end)
        after_each(function()
            _G.api._providers[_G.mock_provider1.protocol_patterns[1]] = nil
            _G.api._providers[_G.mock_provider2.protocol_patterns[1]] = nil
            _G.api._buffer_provider_cache["" .. 1] = _G.cache_buf
            _G.cache_buf = nil
        end)
        it("should throw error on missing path", function()
            assert.has_error(function() _G.api:_get_buffer_cache_object(1) end, '"No path was provided with index: 1!"', "Failed to throw expected missing path error!")
        end)
        it("should throw error about invalid path", function()
            assert.has_error(function() _G.api:_get_buffer_cache_object(1, 'useless_file') end, '"Unable to parse path: useless_file to get protocol!"', "Failed to throw expected invalid path error!")
        end)
        it("should throw error on missing provider for path", function()
            assert.has_error(function() _G.api:_get_buffer_cache_object(1, "junk3://somefile") end, '"Error parsing path: junk3://somefile -- Unable to establish provider"', "Failed to throw expected missing provider error!")
        end)
        it("should return mock_provider1 for uri junk1:// on index 1", function()
            assert.is_equal(_G.api:_get_buffer_cache_object(1, _G.mock_uri1).provider.name, _G.mock_provider1.name, "Failed to return mock_provider1!")
        end)
        it("should return mock_provider2 for uri junk2:// on index 1", function()
            assert.is_equal(_G.api:_get_buffer_cache_object(1, _G.mock_uri2).provider.name, _G.mock_provider2.name, "Failed to return mock_provider2!")
        end)
    end)
    
    describe("load_provider", function()
        describe("valid provider", function()
            after_each(function()
                _G.api._providers[_G.mock_provider1.protocol_patterns[1]] = nil
                _G.api._augroup_defined = false
                vim.api.nvim_command('augroup Netman')
                vim.api.nvim_command('autocmd!')
                vim.api.nvim_command('augroup END')
            end)
            it("should not fail require check", function()
                assert.has_no.errors(function() _G.api:load_provider(_G.mock_provider1.name) end, "Error during load of provider!")
                assert.is_not_nil(_G.api._providers[_G.mock_provider1.protocol_patterns[1]], "Failed to load provider!")
            end)
            it("should add auto group to netman for the provider", function()
                local file_read_command = 'autocmd Netman FileReadCmd ' .. _G.mock_provider1.protocol_patterns[1] .. "://*"
                local buf_read_command = 'autocmd Netman BufReadCmd ' .. _G.mock_provider1.protocol_patterns[1] .. "://*"
                local file_write_command = 'autocmd Netman FileWriteCmd ' .. _G.mock_provider1.protocol_patterns[1] .. "://*"
                local buf_write_command = 'autocmd Netman BufWriteCmd ' .. _G.mock_provider1.protocol_patterns[1] .. "://*"
                local buf_unload_command = 'autocmd Netman BufUnload ' .. _G.mock_provider1.protocol_patterns[1] .. "://*"
                assert.has_no.errors(function() _G.api:load_provider(_G.mock_provider1.name) end, "Failed to load provider!")
                assert.is_not_nil(vim.api.nvim_exec(file_read_command, true):match(_G.mock_provider1.protocol_patterns[1]), "Netman failed to set FileReadCmd Autocommand!")
                assert.is_not_nil(vim.api.nvim_exec(buf_read_command, true):match(_G.mock_provider1.protocol_patterns[1]), "Netman failed to set BufReadCmd Autocommand!")
                assert.is_not_nil(vim.api.nvim_exec(file_write_command, true):match(_G.mock_provider1.protocol_patterns[1]), "Netman failed to set FileWriteCmd Autocommand!")
                assert.is_not_nil(vim.api.nvim_exec(buf_write_command, true):match(_G.mock_provider1.protocol_patterns[1]), "Netman failed to set BufWriteCmd Autocommand!")
                assert.is_not_nil(vim.api.nvim_exec(buf_unload_command, true):match(_G.mock_provider1.protocol_patterns[1]), "Netman failed to set BufUnload Autocommand!")
            end)
            it("should not call init as there is none", function()
                _G.cache_func = _G.mock_provider1.init
                _G.mock_provider1.init = nil
                assert.has_no.errors(function() _G.api:load_provider(_G.mock_provider1.name) end, "Init was called even though it doesn't exist!")
                _G.mock_provider1.init = _G.cache_func
                _G.cache_func = nil
            end)
            it("should call init as there is one", function()
                local g = spy.on(_G.mock_provider1, 'init')
                assert.has_no.errors(function() _G.api:load_provider(_G.mock_provider1.name) end, "Failed to load provider!")
                assert.spy(g).was_called()
                _G.mock_provider1.init:revert()
            end)
        end)
        describe("invalid provider", function()
            before_each(function()
                _G.api._providers[_G.mock_provider1.protocol_patterns[1]] = nil
                package.loaded[_G.mock_provider1.name] = nil
            end)
            after_each(function()
                package.loaded[_G.mock_provider1.name] =_G.mock_provider1
                _G.api._providers[_G.mock_provider1.protocol_patterns[1]] = nil
            end)
            it("should fail require check", function()
                assert.has_error(function() _G.api:load_provider(_G.mock_provider1.name) end, "\"Failed to initialize provider: " .. _G.mock_provider1.name .. ". This is likely due to it not being loaded into neovim correctly. Please ensure you have installed this plugin/provider\"", "Failed to throw error for invalid provider!")
            end)
            it("should not add auto group to netman for the provider", function()
                assert.has_error(function() _G.api:load_provider(_G.mock_provider1.name) end, "\"Failed to initialize provider: " .. _G.mock_provider1.name .. ". This is likely due to it not being loaded into neovim correctly. Please ensure you have installed this plugin/provider\"", "Failed to throw error for invalid provider!")
                local file_read_command = 'autocmd Netman FileReadCmd ^' .. _G.mock_provider1.protocol_patterns[1] .. "://*"
                local buf_read_command = 'autocmd Netman BufReadCmd ^' .. _G.mock_provider1.protocol_patterns[1] .. "://*"
                local file_write_command = 'autocmd Netman FileWriteCmd ^' .. _G.mock_provider1.protocol_patterns[1] .. "://*"
                local buf_write_command = 'autocmd Netman BufWriteCmd ^' .. _G.mock_provider1.protocol_patterns[1] .. "://*"
                local buf_unload_command = 'autocmd Netman BufUnload ^' .. _G.mock_provider1.protocol_patterns[1] .. "://*"
                assert.is_nil(vim.api.nvim_exec(file_read_command, true):match(_G.mock_provider1.protocol_patterns[1]), "Netman set FileReadCmd Autocommand!")
                assert.is_nil(vim.api.nvim_exec(buf_read_command, true):match(_G.mock_provider1.protocol_patterns[1]), "Netman set BufReadCmd Autocommand!")
                assert.is_nil(vim.api.nvim_exec(file_write_command, true):match(_G.mock_provider1.protocol_patterns[1]), "Netman set FileWriteCmd Autocommand!")
                assert.is_nil(vim.api.nvim_exec(buf_write_command, true):match(_G.mock_provider1.protocol_patterns[1]), "Netman set BufWriteCmd Autocommand!")
                assert.is_nil(vim.api.nvim_exec(buf_unload_command, true):match(_G.mock_provider1.protocol_patterns[1]), "Netman set BufUnload Autocommand!")
                _G.api._augroup_defined = false
                vim.api.nvim_command('augroup Netman')
                vim.api.nvim_command('autocmd!')
                vim.api.nvim_command('augroup END')
            end)
        end)
    end)

    describe("unload", function()
        before_each(function()
            _G.api._buffer_provider_cache["" .. 1] = nil
        end)
        after_each(function()
            _G.api._buffer_provider_cache["" .. 1] = nil
        end)
        it("should not unload either provider", function()
            local s1 = spy.on(_G.mock_provider1, 'close_connection')
            local s2 = spy.on(_G.mock_provider2, 'close_connection')
            _G.api:unload(1)
            assert.spy(s1).was_not_called()
            assert.spy(s2).was_not_called()
        end)
        it("should only unload provider1", function()
            local s1 = spy.on(_G.mock_provider1, 'close_connection')
            local s2 = spy.on(_G.mock_provider2, 'close_connection')
            _G.api._buffer_provider_cache["" .. 1] = {}
            _G.api._buffer_provider_cache["" .. 1][_G.mock_provider1.protocol_patterns[1]] = {
                provider = _G.mock_provider1
                ,origin_path = _G.mock_uri
            }
            _G.api:unload(1)
            assert.spy(s1).was_called()
            assert.spy(s2).was_not_called()
        end)
        it("should only unload provider2", function()
            local s1 = spy.on(_G.mock_provider1, 'close_connection')
            local s2 = spy.on(_G.mock_provider2, 'close_connection')
            _G.api._buffer_provider_cache["" .. 1] = {}
            _G.api._buffer_provider_cache["" .. 1][_G.mock_provider2.protocol_patterns[1]] = {
                provider = _G.mock_provider2
                ,origin_path = _G.mock_uri
            }
            _G.api:unload(1)
            assert.spy(s1).was_not_called()
            assert.spy(s2).was_called()
        end)
        it("should unload both providers", function()
            local s1 = spy.on(_G.mock_provider1, 'close_connection')
            local s2 = spy.on(_G.mock_provider2, 'close_connection')
            _G.api._buffer_provider_cache["" .. 1] = {}
            _G.api._buffer_provider_cache["" .. 1][_G.mock_provider1.protocol_patterns[1]] = {
                provider = _G.mock_provider1
                ,origin_path = _G.mock_uri
            }
            _G.api._buffer_provider_cache["" .. 1][_G.mock_provider2.protocol_patterns[1]] = {
                provider = _G.mock_provider2
                ,origin_path = _G.mock_uri
            }
            _G.api:unload(1)
            assert.spy(s1).was_called()
            assert.spy(s2).was_called()
        end)
    end)

    describe("claim_buf_details", function()
        local unclaimed_id = '1234'
        before_each(function()
            _G.api._unclaimed_provider_details = {}
            _G.api._unclaimed_provider_details[unclaimed_id] = {
                provider = _G.mock_provider1
                ,protocol = _G.mock_provider1.protocol_patterns[1]
                ,origin_path = _G.invalid_mock_uri
            }
            _G.api._buffer_provider_cache["" .. 1] = {}
        end)
        after_each(function()
            _G.api._unclaimed_provider_details = {
                
            }
            _G.api._buffer_provider_cache["" .. 1] = {}
        end)
        it("should remove claim id from unclaimed queue", function()
            _G.api:_claim_buf_details(1, unclaimed_id)
            assert.is_nil(_G.api._unclaimed_provider_details[unclaimed_id])
            assert.is_not_nil(_G.api._buffer_provider_cache["1"])
        end)
        it("should not modify unclaimed queue for invalid claim id", function()
            local invalid_unclaimed_id = "1234111"
            _G.api:_claim_buf_details(1, invalid_unclaimed_id)
            assert.is_not_nil(_G.api._unclaimed_provider_details[unclaimed_id])
        end)
    end)
end)
