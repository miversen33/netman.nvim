_G._QUIET = true -- This makes bootstrap shut up
vim.g.netman_log_level = 0

local spy = require("luassert.spy")
local describe = require('busted').describe
local it = require('busted').it
local before_each = require("busted").before_each
local after_each = require("busted").after_each
local pending = require("busted").pending

describe("Netman API #netman-api", function()
    before_each(function()
        package.loaded['netman.api'] = nil
    end)
    describe("#init_config", function()
        local _io = {}
        local _json = {}
        local api = nil
        before_each(function()
            _io.open = _G.io.open
            api = nil
            package.loaded['netman.tools.utils'] = nil
            _json.decode = _G.vim.fn.json_decode
        end)
        after_each(function()
            _G.io.open = _io.open
            api = nil
            _G.vim.fn.json_decode = _json.decode
        end)

        it("should complain that it cant open the configuration", function()
            api = require("netman.api")
            package.loaded['netman.tools.utils'].netman_config_path = ''
            _G.io.open = function() return false end
            assert.has_error(function()
                api.internal.init_config() end,
                "Unable to read netman configuration file: "
            )
        end)
        it("should not try to decode json if there is nothing to decode", function()
            api = require("netman.api")
            package.loaded['netman.tools.utils'].netman_config_path = ''
            _G.io.open = function()
                return {
                    lines = function() return function() return nil end end,
                    close = function() end
                }
            end
            local called = false
            _G.vim.fn.json_decode = function() called = true end
            api.internal.init_config()
            assert.is_false(called, "API attempted to decode invalid lines of configuration")
        end)
    end)
    describe("#init_augroups", function()
        local api = nil
        local _nvim_create_augroup = nil
        local _nvim_create_autocmd = nil
        before_each(function()
            api = require("netman.api")
            _nvim_create_augroup = vim.api.nvim_create_augroup
            _nvim_create_autocmd = vim.api.nvim_create_autocmd
        end)
        after_each(function()
            api = nil
            package.loaded['netman.api'] = nil
            vim.api.nvim_create_augroup = _nvim_create_augroup
            vim.api.nvim_create_autocmd = _nvim_create_autocmd
        end)
        it("should create the Netman auto group", function()
            local was_called = false
            vim.api.nvim_create_augroup = function(group, _)
                if group == 'Netman' then was_called = true end
            end
            api.internal.init_augroups()
            assert.is_true(was_called, "Netman Auto Group was not created")
        end)
        it("should create all needed auto commands", function()
            local required_au_groups = {
                BufEnter = 1,
                FileReadCmd = 1,
                BufReadCmd = 1,
                FileWriteCmd = 1,
                BufWriteCmd = 1,
                BufUnload = 1
            }
            vim.api.nvim_create_autocmd = function(group, _)
                required_au_groups[group] = nil
            end

            api.internal.init_augroups()
            for key, _ in pairs(required_au_groups) do
                assert.is_not_equal(1, _, string.format("%s auto command was not created", key))
            end
        end)
    end)
    describe("#is_path_netman_uri", function()
        -- api.is_path_netman_uri
        it("should return false if there are no registered providers",
            function()
                -- Stubing the netman.providers function as we dont want it to actually work
                package.loaded['netman.providers'] = {}
                local api = require("netman.api")
                assert.is_false(api.is_path_netman_uri('ssh://somehost/somepath'), "SSH check failed to fail")
                assert.is_false(api.is_path_netman_uri('docker://somecontainer/somepath'), "Docker check failed to fail")
                assert.is_false(api.is_path_netman_uri('git://somerepo/somepath'), "Git check failed to fail")
                assert.is_false(api.is_path_netman_uri('jankuri://jankpath'), "Jank check failed to fail")
                assert.is_false(api.is_path_netman_uri('complete_absolute_gibberish'), "Gibberish check failed to fail")
            end
        )
        it("should return false if the URI does not match a registered provider",
            function()
                package.loaded['netman.providers'] = {}
                local api = require("netman.api")
                assert.is_false(api.is_path_netman_uri('git://somerepo/somepath'), "Git check failed to fail")
                assert.is_false(api.is_path_netman_uri('jankuri://jankpath'), "Jank check failed to fail")
                assert.is_false(api.is_path_netman_uri('complete_absolute_gibberish'), "Gibberish check failed to fail")
            end
        )
        it("should return true if the URI does match a registered provider",
            function()
                package.loaded['netman.providers'] = {}
                local api = require("netman.api")
                api._providers.protocol_to_path["dummyuri"] = 'dummy.test.provider'
                api._providers.path_to_provider["dummy.test.provider"] = {
                    provider = "dummy.test.provider",
                    cache = {}
                }
                assert.is_true(api.is_path_netman_uri("dummyuri://somepath"), "Dummy URI failed to be read by registered provider")
            end
        )
    end)
    -- api.internal.validate_uri
    describe("#validate_uri", function()
        it("should return nil if the uri is not a shortcut and there is no provider for it", function()
            package.loaded['netman.providers'] = {}
            local api = require("netman.api")
            assert.is_nil(api.internal.validate_uri("jankuri://somepath"))
        end)
    end)
    -- api.load_provider
    describe("#load_provider", function()
        local required_attrs = {
                'name'
                ,'protocol_patterns'
                ,'version'
                ,'read'
                ,'write'
                ,'delete'
                ,'get_metadata'
        }
        before_each(function()
            package.loaded['netman.providers'] = {}
            package.loaded['dummy.provider'] = nil
            package.loaded['dummy.provider.1'] = nil
            package.loaded['dummy.provider.2'] = nil
            package.loaded['netman.api'] = nil
        end)
        -- We need to test the following things
        it("should not attempt to load a provider that is already loaded", function()
            local spied_importer = spy.new(function() end)
            local api = require("netman.api")
            api._providers.path_to_provider["jankprovider"] = { init = spied_importer }
            api.load_provider("jankprovider")
            assert.spy(spied_importer).was_not_called("Load provider attempted multiple loads of same provider")
        end)
        it("should notify the user when a provider doesn't exist", function()
            local spied_notify = spy.on(require("netman.tools.utils").notify, 'error')
            local api = require("netman.api")
            api.load_provider("non-existent-provider")
            assert.spy(spied_notify).was_called(1)
        end)
        it("should notify the user when a provider is invalid", function()
            package.loaded['dummy.provider.1'] = true
            package.loaded['dummy.provider.2'] = false
            local spied_notify = spy.on(require("netman.tools.utils").notify, 'error')
            local api = require("netman.api")
            api.load_provider('dummy.provider.1')
            assert.spy(spied_notify).was_called(1)
            spied_notify:clear()
            api.load_provider('dummy.provider.2')
            assert.spy(spied_notify).was_called(1)
        end)
        it("should fail to validate an invalid provider", function()
            local dummy_provider = {}
            package.loaded['dummy.provider'] = dummy_provider
            local api = require("netman.api")
            for index, _ in ipairs(required_attrs) do
                for _, attr in ipairs({table.unpack(required_attrs, 1, index)}) do
                    local val = nil
                    if attr == 'name' then val = "dummy_provider"
                    elseif attr == 'version' then val = '0.0'
                    elseif attr == 'protocol_patterns' then val = {'jankuri'}
                    else val = function() end end
                    dummy_provider[attr] = val
                end
                local missing_attrs = unpack(required_attrs, index + 1, #required_attrs)
                api.load_provider('dummy.provider')
                if type(missing_attrs) == 'string' then missing_attrs = {missing_attrs} end
                if missing_attrs then
                    for _, missing_attr in ipairs(missing_attrs) do
                        assert(api._providers.uninitialized["dummy.provider"].reason:find(missing_attr), string.format("Load Provider did not fail for missing attribute %s", missing_attr))
                    end
                end
            end
        end)
        it("should call init if its provided", function()
            local dummy_provider = {}
            for index, _ in ipairs(required_attrs) do
                for _, attr in ipairs({table.unpack(required_attrs, 1, index)}) do
                    local val = nil
                    if attr == 'name' then val = "dummy_provider"
                    elseif attr == 'version' then val = '0.0'
                    elseif attr == 'protocol_patterns' then val = {'jankuri'}
                    else val = function() end end
                    dummy_provider[attr] = val
                end
            end
            package.loaded['dummy.provider'] = dummy_provider
            local api = require("netman.api")

            -- luassert's spy functionality is quite lacking.
            -- Instead of making my own altogether, I am just going
            -- to piece together what I need as I need them
            local _unload_provider = api.unload_provider
            local call_count = 0
            local spied_unload_provider = function(...)
                call_count = call_count + 1
                _unload_provider(...)
                package.loaded['dummy.provider'] = dummy_provider
            end
            api.unload_provider = spied_unload_provider
            dummy_provider.init = function()
                error("DED!")
            end
            api.load_provider('dummy.provider')
            assert.is_equal(1, call_count, "Load Provider did not unload failed provider init!")

            call_count = 0
            dummy_provider.init = function() return false end
            api.load_provider('dummy.provider')
            assert.is_equal(1, call_count, "Load provider did not unload provider with unsafe init")

            call_count = 0
            dummy_provider.init = function() end
            api.load_provider('dummy.provider')
            assert.is_equal(1, call_count, "Load Provider did not unload provider with no init return")

            call_count = 0
            dummy_provider.init = function() return true end
            assert.is_equal(0, call_count, "Load Provider unloaded properly inited provider")
            api.unload_provider = _unload_provider
        end)
        it("should override existing provider of same protocol pattern", function()
            local dummy_provider1 = {}
            local dummy_provider2 = {}
            for index, _ in ipairs(required_attrs) do
                for _, attr in ipairs({table.unpack(required_attrs, 1, index)}) do
                    local val = nil
                    if attr == 'name' then val = "dummy_provider"
                    elseif attr == 'version' then val = '0.0'
                    elseif attr == 'protocol_patterns' then val = {'jankuri'}
                    else val = function() end end
                    dummy_provider1[attr] = val
                    dummy_provider2[attr] = val
                end
            end
            package.loaded['dummy.provider.1'] = dummy_provider1
            package.loaded['dummy.provider.2'] = dummy_provider2
            local api = require("netman.api")
            api.load_provider('dummy.provider.1')

            local call_count = 0
            local overriden_name = nil
            local _unload_provider = api.unload_provider
            api.unload_provider = function(...)
                call_count = call_count + 1
                overriden_name = select(1, ...)
                _unload_provider(...)
            end
            api.load_provider('dummy.provider.2')
            assert.is_equal(1, call_count, "Load Provider did not unload overriden provider!")
            assert.is_equal('dummy.provider.1', overriden_name, "Load Provider did not unload the correct provider on override")
        end)
        it("should prevent core providers for overriding third party providers", function()
            local dummy_provider1 = {}
            local dummy_provider2 = {}
            for index, _ in ipairs(required_attrs) do
                for _, attr in ipairs({table.unpack(required_attrs, 1, index)}) do
                    local val = nil
                    if attr == 'name' then val = "dummy_provider"
                    elseif attr == 'version' then val = '0.0'
                    elseif attr == 'protocol_patterns' then val = {'jankuri'}
                    else val = function() end end
                    dummy_provider1[attr] = val
                    dummy_provider2[attr] = val
                end
            end
            package.loaded['dummy.provider.1'] = dummy_provider1
            package.loaded['netman.providers.dummy_provider'] = dummy_provider2
            local api = require("netman.api")
            api.load_provider('dummy.provider.1')
            api.load_provider('netman.providers.dummy_provider')
            assert.is_not_nil(api._providers.uninitialized['netman.providers.dummy_provider'], "Load Provider allowed core provider to override third party provider")
        end)
    end)
    -- api.unload_provider
    describe("#unload_provider", function()
        before_each(function()
            package.loaded['netman.providers'] = {}
            package.loaded['dummy.provider.1'] = nil
            package.loaded['dummy.provider.2'] = nil
            package.loaded['netman.api'] = nil
        end)
        it("should silently fail when unloading an invalid provider", function()
            assert.has_no.errors(
                function() require("netman.api").unload_provider("dummy.provider") end,
                "Unload Provider failed to safely unload invalid provider"
            )
        end)
        it("should unload all hooks for a provider", function()
            local dummy_provider1 = {}
            dummy_provider1.protocol_patterns = { "junkuri" }
            package.loaded['dummy.provider.1']= dummy_provider1
            local api = require("netman.api")
            api._providers.protocol_to_path['junkuri'] = 'dummy.provider.1'
            api._providers.path_to_provider['dummy.provider.1'] = dummy_provider1
            api.unload_provider('dummy.provider.1')
            assert.is_nil(api._providers.protocol_to_path['junkuri'], "Unload Provider failed to remove protocol to path map")
            assert.is_nil(api._providers.path_to_provider['dummy.provider.1'], "Unload Provider failed to remove provider path map")
        end)
        it("should burn all traces of the provider for memory", function()
            local dummy_provider1 = {}
            dummy_provider1.protocol_patterns = { "junkuri" }
            package.loaded['dummy.provider.1']= dummy_provider1
            local api = require("netman.api")
            api._providers.protocol_to_path['junkuri'] = 'dummy.provider.1'
            api._providers.path_to_provider['dummy.provider.1'] = dummy_provider1
            api.unload_provider('dummy.provider.1')
            assert.is_nil(api._providers.protocol_to_path['junkuri'], "Unload Provider failed to remove protocol to path map")
            assert.is_nil(api._providers.path_to_provider['dummy.provider.1'], "Unload Provider failed to remove provider path map")
            assert.is_nil(package.loaded['dummy.provider.1'], "Unload Provider failed to remove provider from lua memory")
        end)
        it("should justify the removal of the provider for later viewing", function()
            local dummy_provider1 = {}
            dummy_provider1.protocol_patterns = { "junkuri" }
            package.loaded['dummy.provider.1']= dummy_provider1
            local api = require("netman.api")
            api._providers.protocol_to_path['junkuri'] = 'dummy.provider.1'
            api._providers.path_to_provider['dummy.provider.1'] = dummy_provider1
            api.unload_provider('dummy.provider.1')
            assert.is_not_nil(api._providers.uninitialized['dummy.provider.1'], "Unload Provider did _not_ justify the removal of the provider")
        end)
    end)
    describe("#unload_buffer", function()
        before_each(function()
        -- "Load" a provider and uri into memory to verify that things work as expected
        end)
        pending("should call \"close_connection\" on an associated provider after buffer is closed", function()
        end)
    end)
    -- api.internal.read_as_stream
    describe("#read_as_stream", function()
        it("should create valid read command from input data, with approriate filetype", function()
            local read_data = {"line1", "line2", "line3"}
            local command = require("netman.api").internal.read_as_stream(read_data, "netman-test")
            local comp_command = string.format("0append! %s | set nomodified | filetype netman-test", table.concat(read_data, "\n"))
            assert.is_equal(command, comp_command, "Read As Stream failed to generated approriate command with filetype")
        end)
        it("should create valid read command from input data, with \"detect\" filetype", function()
            local read_data = {"line1", "line2", "line3"}
            local command = require("netman.api").internal.read_as_stream(read_data)
            local comp_command = string.format("0append! %s | set nomodified | filetype detect", table.concat(read_data, "\n"))
            assert.is_equal(command, comp_command, "Read As Stream failed to generated approriate command with detect filetype")
        end)
    end)
    -- api.internal.read_as_file
    describe('#read_as_file', function()
        it("should create valid read command from input data, with approriate filetype", function()
            local read_data = {local_path="local_path"}
            local command = require("netman.api").internal.read_as_file(read_data, "netman-test")
            local comp_command = string.format("read ++edit %s | set nomodified | filetype netman-test", read_data.local_path)
            assert.is_equal(command, comp_command, "Read As File failed to generated approriate command with filetype")
        end)
        it("should create valid read command from input data, with \"detect\" filetype", function()
            local read_data = {local_path="local_path"}
            local command = require("netman.api").internal.read_as_file(read_data)
            local comp_command = string.format("read ++edit %s | set nomodified | filetype detect", read_data.local_path)
            assert.is_equal(command, comp_command, "Read As Stream failed to generated approriate command with detect filetype")
        end)
    end)
    -- api.read
    describe('#read', function()
        local api = nil
        local api_options = require("netman.tools.options").api
        local provider = nil
        local read_as_stream_spy = nil
        local read_as_file_spy = nil
        local read_as_explore_spy = nil
        before_each(function()
            api = require("netman.api")
            provider = nil
            api.internal.validate_uri = function(uri) return uri, provider end

            read_as_stream_spy = spy.on(api.internal, 'read_as_stream')
            read_as_file_spy = spy.on(api.internal, 'read_as_file')
            read_as_explore_spy = spy.on(api.internal, 'read_as_explore')
        end)
        after_each(function()
            package.loaded['netman.api'] = nil
        end)
        it("should call read_as_stream if no type is returned by provider", function()
            provider = {
                read = function() return "" end
            }
            api.read('')
            assert.spy(read_as_stream_spy).was_called()
        end)
        it("should return nil if an invalid read type was returned by provider", function()
            provider = {
                read = function() return '', 'invalid read type' end
            }
            assert.is_nil(api.read(''))
        end)
        it("should return nil if no data was returned by the provider", function()
            provider = {
                read = function() end
            }
            assert.is_nil(api.read(''))
        end)
        it("should call read_as_stream if the provider said its a stream", function()
            provider = {
                read = function() return '', api_options.READ_TYPE.STREAM end
            }
            api.read('')
            assert.spy(read_as_stream_spy).was_called()
        end)
        it("should call read_as_file if the provider said its a file", function()
            provider = {
                read = function()
                    return
                        {local_path='', origin_path=''},
                        api_options.READ_TYPE.FILE,
                        {local_parent='', remote_parent=''}
                end
            }
            api.read('')
            assert.spy(read_as_file_spy).was_called()
        end)
        it("should call read_as_explore if the provider said its a link", function()
            provider = {
                read = function()
                    return
                        {remote_files={}},
                        api_options.READ_TYPE.EXPLORE,
                        {local_parent='', remote_parent=''}
                end
            }
            api.read('')
            assert.spy(read_as_explore_spy).was_called()
        end)
    end)
    -- api.write
    describe('#write', function()
        -- Figure out a way to verify that an action is happening asychronously?
        -- A reasonable way to do this would be to have our provider's 
        -- "write" function do a sleep for some (very short) amount of time.
        -- Anything longer than nothing would mean that it should still be running
        -- when api.write finishes and thus we can verify that it is asynchronous.
        -- If the "long running" write function is complete by the time api.write
        -- finishes, that means it was _not_ async. Das bad
        local api = nil
        local provider = nil
        local _nvim_buf_get_lines = nil
        before_each(function()
            api = require("netman.api")
            provider = nil
            api.internal.validate_uri = function(uri) return uri, provider end
            _nvim_buf_get_lines = vim.api.nvim_buf_get_lines
            -- Adding the empty params because sumneko complains like a ass
            -- when other things are using the _real_ vim.api.nvim_buf_get_lines
            vim.api.nvim_buf_get_lines = function(_, _, _, _) return {"line1"} end
        end)
        after_each(function()
            vim.api.nvim_buf_get_lines = _nvim_buf_get_lines
            package.loaded['netman.api'] = nil
        end)
        pending("should call write asynchronously", function()

        end)
        it("should call the provider's write function", function()
            local ran = false
            provider = {
                write = function()
                    ran = true
                end
            }
            api.write(0, '')
            assert.is_true(ran, "Write did not call provider's write function")
        end)
        it("should return nil and do nothing if there is no provider for the uri", function()
            assert.is_nil(api.write(0, ''), "Write somehow got a provider to use?")
        end)
    end)
    -- api.delete
    describe('#delete', function()
        -- Figure out a way to verify that an action is happening asychronously?
        -- A reasonable way to do this would be to have our provider's 
        -- "delete" function do a sleep for some (very short) amount of time.
        -- Anything longer than nothing would mean that it should still be running
        -- when api.delete finishes and thus we can verify that it is asynchronous.
        -- If the "long running" delete function is complete by the time api.delete
        -- finishes, that means it was _not_ async. Das bad
        local api = nil
        local provider = nil
        before_each(function()
            api = require("netman.api")
            provider = nil
            api.internal.validate_uri = function(uri) return uri, provider end
        end)
        after_each(function()
            package.loaded['netman.api'] = nil
        end)
        pending("should call delete asychronously", function()
        
        end)
        it("should call the provider's delete function", function()
            local ran = false
            provider = {
                delete = function()
                    ran = true
                end
            }
            api.delete(0, '')
            assert.is_true(ran, "Delete did not call provider's delete function")
        end)
        it("should return nil and do nothing if there is no provider for the uri", function()
            assert.is_nil(api.delete(0, ''), "Delete somehow got a provider to use?")
        end)
    end)
    -- api.register_explorer_package
    describe('#register_explorer_package', function()
        local api = nil
        local package_name = 'netman-unittest-package'
        before_each(function()
            api = require("netman.api")
        end)
        after_each(function()
            package.loaded['netman.api'] = nil
        end)
        it("should not register a nil package", function()
            api.register_explorer_package()
            assert.is_nil(api._explorers[package_name], "API somehow registered no package name??")
        end)
        it("should sanitize the package name", function()
            local t_package = "netman.unitest.package"
            api.register_explorer_package(t_package)
            assert.is_equal(api._explorers[t_package], 'netman%.unitest%.package', "Sanitization failed")
        end)
        it("should save the package as an explorer", function()
            local t_package = "netman.unitest.package"
            api.register_explorer_package(t_package)
            assert.is_not_nil(api._explorers[t_package], "Failed to register explorer")
        end)
    end)
    -- api.init
    describe('#init', function()
        after_each(function()
            package.loaded['netman.api'] = nil
        end)
        it("should init the auto groups", function()
            local was_called = false
            local api = require("netman.api")
            api.internal.init_augroups = function() was_called = true end
            api._inited = nil
            api.init()
            assert.is_true(was_called, "API init did not reach out to create au groups")
        end)
        it("should should load system providers", function()
            local system_providers = require("netman.providers")
            local api = require("netman.api")
            for _, provider in ipairs(system_providers) do
                assert.is_not_nil(api._providers.path_to_provider[provider], string.format("API did not load system provider %s", provider))
            end
        end)
    end)
    -- api.get_metadata
    describe("#get_metadata", function()
        local api = nil
        local was_called = nil
        before_each(function()
            api = require("netman.api")
            was_called = false
            local provider = {
                get_metadata = function(_, _, keys)
                    was_called = true
                    local metadata = {}
                    for _, key in ipairs(keys) do
                        metadata[key] = 1
                    end
                    return metadata
                end
            }
            api.internal.validate_uri = function(_)
                return _, provider
            end
        end)
        after_each(function()
            was_called = false
            package.loaded['netman.api'] = nil
        end)
        it("should have a default set of metadata keys to return if you don't provide any", function()
            local metadata = api.get_metadata('')
            assert.is_not_nil(metadata, "API did not return a default keyset for metadata")
        end)
        it("should return the metadata for the provided keys", function()
            local metadata_keys = {'ATIME_SEC'}
            local metadata = api.get_metadata('', metadata_keys)
            assert.is_not_nil(metadata[metadata_keys[1]], string.format("API did not return the requested valid metadata for %s", metadata_keys[1]))
        end)
        it("should reach out to the provider to get metadata", function()
            api.get_metadata('')
            assert.is_true(was_called, "API did not reach out to the provider")
        end)
        it("should sanitize the provider's returned metadata keys to ensure consistency", function()
            local metadata_keys = {'ATIME_SEC', 'INVALID_KEY'}
            local metadata = api.get_metadata('', metadata_keys)
            assert.is_not_nil(metadata[metadata_keys[1]], string.format("API did not return metadata for valid metadata key %s", metadata_keys[1]))
            assert.is_nil(metadata[metadata_keys[2]], string.format("API returned metadata for invalid metadata key %s", metadata_keys[2]))
        end)
    end)
end)
