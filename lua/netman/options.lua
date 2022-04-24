return {
    utils = {
        command = {
             IGNORE_WHITESPACE_ERROR_LINES  = 
                'IGNORE_WHITESPACE_ERROR_LINES'
            ,IGNORE_WHITESPACE_OUTPUT_LINES = 
                'IGNORE_WHITESPACE_OUTPUT_LINES'
            ,STDOUT_JOIN = "STDOUT_JOIN"
            ,STDERR_JOIN = "STDERR_JOIN"
            ,SHELL_ESCAPE = "SHELL_ESCAPE"
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
        METADATA = {
            PERMISSIONS = "PERMISSIONS"
            ,OWNER_USER = "OWNER_USER"
            ,OWNER_GROUP = "OWNER_GROUP"
            ,SIZE_LABEL = "SIZE_LABEL"
            ,SIZE = "SIZE"
            ,GROUP = "GROUP"
            ,PARENT = "PARENT"
            ,FIELD_TYPE = "FIELD_TYPE"
            ,TYPE = "TYPE"
            ,INODE = "INODE"
            ,LASTACCESS = "LAST_ACCESS"
            ,FULLNAME = "FULLNAME"
            ,URI = "URI"
            ,NAME = "NAME"
            ,LINK = "LINK"
            ,DESTINATION = "DESTINATION"
        }
        ,FIELDS = {
            FIELD_TYPE = "FIELD_TYPE"
            ,NAME = "NAME"
            ,URI = "URI"
        }
    }
}
