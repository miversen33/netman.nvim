_G._QUIET = true -- This makes bootstrap shut up
require("lua.netman.tools.bootstrap")
vim.g.netman_log_level = 0

local describe = require("busted").describe
local it = require("busted").it
local before_each = require("busted").before_each
local after_each = require("busted").after_each
local pending = require("busted").pending

describe('Netman init #netman-init', function()
    before_each(function()
        package.loaded['netman.api'] = nil
        package.loaded['netman'] = nil
    end)
    describe('#read', function()
        local _nvim_command = nil
        before_each(function()
            _nvim_command = vim.api.nvim_command
        end)
        after_each(function()
            package.loaded['netman.api'] = nil
            vim.api.nvim_command = _nvim_command
        end)
        it("should not reach out to API for nil files", function()
            local was_called = false
            require("netman.api").read = function(_) was_called = true end
            require("netman").read(nil, nil)
            assert.is_false(was_called, "Read reached out to API with invalid file/uri")
        end)
        it("should not run if a command is not returned by API", function()
            local open_file_command = 'file dummy-file'
            local was_opened = false
            require("netman.api").read = function() end
            vim.api.nvim_command = function(_)
                if _ == open_file_command then
                    was_opened = true
                end
            end
            require("netman").read('dummy-file')
            assert.is_false(was_opened, "Read tried to open nonexistent file off api command")
        end)
        -- What happens when you try to open a uri that is already open?
        -- it("should 
    end)
    describe('#write', function()
        it("should use the buffer filename if no uri is provided", function()
            local was_called = false
            vim.fn.expand = function(_)
                was_called = true
                return 'dummy-file'
            end
            vim.fn.bufnr = function(_) return 0 end
            require("netman.api").write = function() end
            require("netman").write()
            assert.is_not_false(was_called, "Write did not attempt to get file name")
        end)
        it("should throw an error if no uri is able to be found", function()
            local _error = nil
            vim.fn.expand = function(_) end
            require("netman.tools.utils").notify.error = function(_) _error = _ end
            require("netman").write()
            assert.is_not_nil(_error, "Write did not throw an error on invalid uri")
        end)
        it("should call the api's write", function()
            local was_called = false
            vim.fn.expand = function(_) return 'dummy-file' end
            vim.fn.bufnr = function(_) return 0 end
            require("netman.api").write = function() was_called = true end
            require("netman").write()
            assert.is_not_false(was_called, "Write did not reach out to API")
        end)
        it("should set the buffer to be \"nomodified\"", function()
            local command = nil
            local expected_command = "sil! set nomodified"
            vim.fn.expand = function(_) return 'dummy-file' end
            vim.fn.bufnr = function(_) return 0 end
            vim.api.nvim_command = function(_) command = _ end
            require("netman.api").write = function() end
            require("netman").write()
            assert.is_equal(expected_command, command, "Write did not set the buffer to the approriate modified state")
        end)
    end)
    describe('#delete', function()
        it("should warn and do nothing on no uri", function()
            local warn_called = false
            local api_called = false
            require("netman.tools.utils").notify.warn = function(_) warn_called = true end
            require("netman.api").delete = function(_) api_called = true end
            require("netman").delete()
            assert.is_not_false(warn_called, "Delete did not warn on invalid uri")
            assert.is_false(api_called, "Delete reached out to API on invalid uri")
        end)
        it("should reach out to api.delete", function()
            local api_called = false
            require("netman.api").delete = function(_) api_called = true end
            require("netman").delete('')
            assert.is_not_false(api_called, "Delete did not reach out to API")
        end)
    end)
    describe('#init', function()
        local _nvim_command = nil
        before_each(function()
            package.loaded['netman'] = nil
            _nvim_command = vim.api.nvim_command
        end)
        after_each(function()
            vim.api.nvim_command = _nvim_command
        end)
        it("should create the required vim commands", function()
            local required_commands = {
                NmloadProvider = 0,
                NmunloadProvider = 0,
                Nmlogs = 0,
                Nmdelete = 0,
                Nmread = 0,
                Nmwrite = 0,
                Nmbrowse = 0
            }
            vim.api.nvim_command = function(_)
                for command, state in pairs(required_commands) do
                    if state == 0 and string.find(_, command) then
                        required_commands[command] = 1
                    end
                end
            end
            require("netman")
            for command, state in pairs(required_commands) do
                assert.is_equal(1, state, string.format("Init did not create %s command", command))
            end
        end)
    end)
    describe('#misc', function()
        local netman = require("netman")
        it("should expose api", function()
            assert.is_not_nil(netman.api, "Netman init didn't expose API")
        end)
        it("should expose log", function()
            assert.is_not_nil(netman.log, "Netman init didn't expose log")
        end)
        it("should expose notify", function()
            assert.is_not_nil(netman.notify, "Netman init didn't expose notify")
        end)
        it("should expose utils", function()
            assert.is_not_nil(netman.utils, "Netman init didn't expose utils")
        end)
        it("should expose read", function()
            assert.is_not_nil(netman.read, "Netman init didn't expose read")
        end)
        it("should expose write", function()
            assert.is_not_nil(netman.write, "Netman init didn't expose write")
        end)
        it("should expose delete", function()
            assert.is_not_nil(netman.delete, "Netman init didn't expose delete")
        end)
    end)
end)

