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
            -- This should match what is available from libuv's fs_statpath https://github.com/luvit/luv/blob/master/docs.md#uvfs_statpath-callback
            -- Consider trying to interface with `stat` in your provider (if possible) as most of these are pretty easy
            -- to get from that
            ATIME_SEC = "ATIME_SEC"
            ,ATIME_NSEC = "ATIME_NSEC"
            ,BAVAIL = "BAVAIL"
            ,BFREE = "BFREE"
            ,BLKSIZE = "BLKSIZE"
            ,BLOCKS = "BLOCKS"
            ,BSIZE = "BSIZE"
            ,BTIME_SEC = "BTIME_SEC"
            ,BTIME_NSEC = "BTIME_NSEC"
            ,CTIME_SEC = "CTIME_SEC"
            ,CTIME_NSEC = "CTIME_NSEC"
            ,DESTINATION = "DESTINATION"
            ,DEV = "DEV"
            ,FIELD_TYPE = "FIELD_TYPE"
            ,FFREE = "FFREE"
            ,FILES = "FILES"
            ,FLAGS = "FLAGS"
            ,FULLNAME = "FULLNAME"
            ,GEN = "GEN"
            ,GID = "GID"
            ,GROUP = "GROUP"
            ,INODE = "INO"
            ,LASTACCESS = "LAST_ACCESS"
            ,LINK = "LINK"
            ,MODE = "MODE"
            ,MTIME_SEC = "MTIME_SEC"
            ,MTIME_NSEC = "MTIME_NSEC"
            ,NAME = "NAME"
            ,NLINK = "NLINK"
            ,USER = "OWNER_USER"
            ,RDEV = "RDEV"
            ,PARENT = "PARENT"
            ,PERMISSIONS = "PERMISSIONS"
            ,SIZE = "SIZE"
            ,SIZE_LABEL = "SIZE_LABEL"
            ,TYPE = "TYPE"
            ,UID = "UID"
            ,URI = "URI"
        }
        ,FIELDS = {
            FIELD_TYPE = "FIELD_TYPE"
            ,NAME = "NAME"
            ,URI = "URI"
        }
    }
}
