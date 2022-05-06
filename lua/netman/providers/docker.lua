local M = {}

M.protocol_patterns = {'docker'}
M.name = 'docker'
M.version = 0.1

function M:read(uri, cache)

end

function M:write(buffer_index, uri, cache)

end

function M:delete(uri, cache)

end

function M:get_metadata(requested_metadata)

end

function M:init(config_options)

    return true
end

function M:close_connection(buffer_index, uri, cache)

end

return M