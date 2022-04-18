return {
    utils = {
        command = {
             IGNORE_WHITESPACE_ERROR_LINES  = 'IGNORE_WHITESPACE_ERROR_LINES'
            ,IGNORE_WHITESPACE_OUTPUT_LINES = 'IGNORE_WHITESPACE_OUTPUT_LINES'
            ,STDOUT_JOIN = "STDOUT_JOIN"
            ,STDERR_JOIN = "STDERR_JOIN"
        }
    }
    ,api = {
        READ_TYPE = {
            FILE = "FILE"
            ,STREAM = "STREAM"
            ,EXPLORE = "EXPLORE"
        }
        ,ATTRIBUTES = {
            FILE = "FILE"
            ,DIRECTORY = "DIRECTORY"
            ,LINK = "LINK"
        }
    }
    ,protocol = {
        EXPLORE = 'EXPLORE'
    }
    ,explorer = {
        REQUIRED = {
            ATTR = 'ATTR'
            ,NAME = 'NAME'
            ,UNIQUE_NAME = 'UNIQUE_PATH'
        }
        ,OPTIONAL = {
            FULL_PATH = 'FULL_PATH'
            ,OWNERSHIP = 'OWNERSHIP'
            ,PERMISSION = 'PERMISSION'
            ,TYPE = 'TYPE'
        }
    }
}