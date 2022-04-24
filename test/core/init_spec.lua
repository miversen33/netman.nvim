local mock = require('luassert.mock')
local stub = require('luassert.stub')
local spy = require('luassert.spy')

describe("Netman init #netman-init", function()

    require("netman.utils").adjust_log_level(1)

    _G.api = {
        read = function() end,
        write = function() end,
        delete = function() end,
    }
    _G.mock_uri = "junk123://file"
    package.loaded['netman.api'] = _G.api
    _G.netman = require('netman')

    describe("read", function()
        it("read should exist", function()
            assert.is_not_nil(_G.netman.read, "Netman read function is missing")
        end)
        it("should call netman.api.read", function()
            local s = spy.on(_G.api, 'read')
            assert.has_no_error(function() _G.netman:read('uri://somefile1/', 'uri://somefile2/') end, "Failed to read dummy files without error!")
            assert.spy(s).was_called()
            _G.api.read:revert()
        end)
    end)

    describe("write", function()
        it("write should exist", function()
            assert.is_not_nil(_G.netman.write, "Netman write function is missing")
        end)
        -- TODO(Mike): These cant be done without having some sort of vim shim built
        -- to open an editor with neovim since there is a default
        -- check for the name of the buffer and the buffer doesn't
        -- exist

        pending("should call netman.api.write for current buffer")
        pending("should call netman.api.write for uri junk123://file")
        -- it("should call netman.api.write for current buffer", function()
        --     local s = spy.on(_G.api, 'write')
        --     assert.has_no_error(function() _G.netman:write() end, "Failed to write buffer without error!")
        --     assert.spy(s).was_called_with(1, _G.mock_uri)
        --     _G.api.write:revert()
        -- end)
        -- it("should call netman.api.write for uri junk123://file", function()
        --     local s = spy.on(_G.api, 'write')
        --     assert.has_no_error(function() _G.netman:write(_G.mock_uri) end, "Failed to write buffer without error!")
        --     assert.spy(s).was_called()
        --     _G.api.write:revert()
        -- end)
    end)

    describe("delete", function()
        it("delete should exist", function()
            assert.is_not_nil(_G.netman.delete, "Netman delete function is missing")
        end)
        it("should call not netman.api.delete", function()
            local s = spy.on(_G.api, 'delete')
            assert.has_no_error(function() _G.netman:delete() end, "Called netman.api.delete with invalid uri")
            assert.spy(s).was_not_called()
            _G.api.delete:revert()
        end)
        it("should call netman.api.delete", function()
            local s = spy.on(_G.api, 'delete')
            assert.has_no_error(function() _G.netman:delete(_G.mock_uri) end, "Failed to delete dummy files without error!")
            assert.spy(s).was_called()
            _G.api.delete:revert()
        end)
    end)

    describe("config", function()
        
    end)

    describe("init", function()
        before_each(function()
            _G.netman._setup_commands = false
            vim.api.nvim_command("comclear")
            _G.netman:init()
        end)
        after_each(function()
            _G.netman._setup_commands = false
            vim.api.nvim_command("comclear")
        end)
        it("Nmread should be accessible", function()
            assert.is_not_nil(vim.api.nvim_exec('filter Nmread command', true):match('Nmread'), "Nmread command missing!")
        end)
        it("Nmwrite should be accessible", function()
            assert.is_not_nil(vim.api.nvim_exec('filter Nmwrite command', true):match('Nmwrite'), "Nmwrite command missing!")
        end)
        it("Nmdelete should be accessible", function()
            assert.is_not_nil(vim.api.nvim_exec('filter Nmdelete command', true):match('Nmdelete'), "Nmdelete command missing!")
        end)
        it("Nmbrowse should be accessible", function()
            assert.is_not_nil(vim.api.nvim_exec('filter Nmbrowse command', true):match('Nmbrowse'), "Nmbrowse command missing!")
        end)
        it("Nmlogs should be accessible", function()
            assert.is_not_nil(vim.api.nvim_exec('filter Nmlogs command', true):match('Nmlogs'), "Nmlogs command missing!")
        end)
        it("NmloadProvider should be accessible", function()
            assert.is_not_nil(vim.api.nvim_exec('filter NmloadProvider command', true):match('NmloadProvider'), "NmloadProvider command missing!")
        end)
    end)
end)