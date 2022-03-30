describe("Remote tools #remote-tools", function()
    _G.remote_tools = require('netman.remote_tools')
    _G.mock_provider_path = "mock_provider"
    _G.mock_provider = {
        name = 'mock_provider',
        protocol_patterns = {'mock_provider'},
        version = '0.0',
        get_details = function() end,
        get_unique_name = function() end,
        read_file = function() end,
        read_directory = function() end,
        write_file = function() end,
        create_directory = function() end,
        delete_file = function() end,
        delete_directory = function() end
    }
    package.loaded[_G.mock_provider_path] = _G.mock_provider
    describe("API", function()
        before_each(function()
            require('netman.utils').adjust_log_level(0)
        end)
        after_each(function()
            vim.g.netman_remotetools_setup = nil
        end)
        describe("init", function()
            it("should accept any uri provider", function()
                assert(_G.remote_tools.init({
                    providers = { mock_provider_path }
                }), "Failed to initialize remote tools with mock provider")
                assert.is.equal(vim.g.netman_remotetools_setup, 1, "Failed to finalize remote tools initialization")
            end)
        end)
        describe("load_provider", function()
            it("should complain about missing name attribute", function()
                local name = _G.mock_provider.name
                _G.mock_provider.name = nil
                assert.is_equal(_G.remote_tools.load_provider(mock_provider_path, _G.mock_provider), '', "Remote Tools accepted invalid name!")
                _G.mock_provider.name = name
            end)
            it("should complain about missing protocol_patterns attribute", function()
                local pattern = _G.mock_provider.protocol_patterns
                _G.mock_provider.protocol_patterns = nil
                assert.is_equal(_G.remote_tools.load_provider(mock_provider_path, _G.mock_provider), '', "Remote Tools accepted invalid protocol patterns!")
                _G.mock_provider.protocol_patterns = pattern
            end)
            it("should complain about missing version attribute", function()
                local version = _G.mock_provider.version
                _G.mock_provider.version = nil
                assert.is_equal(_G.remote_tools.load_provider(mock_provider_path, _G.mock_provider), '', "Remote Tools accepted invalid version!")
                _G.mock_provider.version = version
            end)
            it("should complain about missing get_details function", function()
                local get_details = _G.mock_provider.get_details
                _G.mock_provider.get_details = nil
                assert.is_equal(_G.remote_tools.load_provider(mock_provider_path, _G.mock_provider), '', "Remote Tools accepted missing get_details function!")
                _G.mock_provider.get_details = get_details
            end)
            it("should complain about missing get_unique_name function", function()
                local get_unique_name = _G.mock_provider.get_unique_name
                _G.mock_provider.get_unique_name = nil
                assert.is_equal(_G.remote_tools.load_provider(mock_provider_path, _G.mock_provider), '', "Remote Tools accepted missing get_unique_name function!")
                _G.mock_provider.get_unique_name = get_unique_name
            end)
            it("should complain about missing read_file function", function()
                local read_file = _G.mock_provider.read_file
                _G.mock_provider.read_file = nil
                assert.is_equal(_G.remote_tools.load_provider(mock_provider_path, _G.mock_provider), '', "Remote Tools accepted missing read_file function!")
                _G.mock_provider.read_file = read_file
            end)
            it("should complain about missing read_directory function", function()
                local read_directory = _G.mock_provider.read_directory
                _G.mock_provider.read_directory = nil
                assert.is_equal(_G.remote_tools.load_provider(mock_provider_path, _G.mock_provider), '', "Remote Tools accepted missing read_directory function!")
                _G.mock_provider.read_directory = read_directory
            end)
            it("should complain about missing write_file function", function()
                local write_file = _G.mock_provider.write_file
                _G.mock_provider.write_file = nil
                assert.is_equal(_G.remote_tools.load_provider(mock_provider_path, _G.mock_provider), '', "Remote Tools accepted missing write_file function!")
                _G.mock_provider.write_file = write_file
            end)
            it("should complain about missing create_directory function", function()
                local create_directory = _G.mock_provider.create_directory
                _G.mock_provider.create_directory = nil
                assert.is_equal(_G.remote_tools.load_provider(mock_provider_path, _G.mock_provider), '', "Remote Tools accepted missing create_directory function!")
                _G.mock_provider.create_directory = create_directory
            end)
            it("should complain about missing delete_file function", function()
                local delete_file = _G.mock_provider.delete_file
                _G.mock_provider.delete_file = nil
                assert.is_equal(_G.remote_tools.load_provider(mock_provider_path, _G.mock_provider), '', "Remote Tools accepted missing delete_file function!")
                _G.mock_provider.delete_file = delete_file
            end)
            it("should complain about missing delete_directory function", function()
                local delete_directory = _G.mock_provider.delete_directory
                _G.mock_provider.delete_directory = nil
                assert.is_equal(_G.remote_tools.load_provider(mock_provider_path, _G.mock_provider), '', "Remote Tools accepted missing delete_directory function!")
                _G.mock_provider.delete_directory = delete_directory
            end)
        end)
        describe("get_remote_file", function()
        
        end)
        describe("get_remote_files", function()
        
        end)
        describe("save_remote_file", function()
        
        end)
        describe("create_remote_directory", function()

        end)
        describe("delete_remote_file", function()
        
        end)
        describe("get_remote_details", function()
        
        end)
        describe("cleanup", function()
        
        end)
        describe("get_providers_info", function()
        
        end)
    end)

    describe("internal", function()
    
    end)
end)