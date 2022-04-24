local providers = require("netman.providers")
local explore_pattern = require("netman.options").protocol.EXPLORE

vim.g.netman_log_level = 1

describe("Netman providers #netman-providers", function()
    for _, provider_path in ipairs(providers) do
        describe(provider_path, function()
            local provider = assert(require(provider_path))
            if provider.protocol_patterns == explore_pattern then goto continue end
            describe("write", function()
                it("should have a write function", function()
                    assert.is_not_nil(provider.write, provider_path .. " is missing write!")
                end)
                pending()
            end)
            describe("read", function()
                it("should have a read function", function()
                    assert.is_not_nil(provider.read, provider_path .. " is missing read!")
                end)
                pending()
            end)
            describe("delete", function()
                it("should have a delete function", function()
                    assert.is_not_nil(provider.delete, provider_path .. " is missing delete!")
                end)
                pending()
            end)
            describe("name", function()
                it("should have a name attribute", function()
                    assert.is_not_nil(provider.name, provider_path .. " is missing a name!")
                end)
                pending()
            end)
            describe("protocol_patterns", function()
                it("should have a protocol_patterns table", function()
                    assert.is_not_nil(provider.protocol_patterns, provider_path .. " is missing protocol_patterns!")
                end)
                pending()
            end)
            describe("version", function()
                it("should have a version attribute", function()
                    assert.is_not_nil(provider.version, provider_path .. " is missing a version!")
                end)
                pending()
            end)
            if provider.init then
                pending("test init function")
            end
            if provider.close_connection then
                pending("test close_connection function")
            end
            ::continue::
        end)
    end
end)