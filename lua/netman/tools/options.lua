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
            ,ASYNC = "ASYNC"
            ,ASYNC_CALLBACK = "ASYNC_CALLBACK"
        }
        ,LRU_CACHE_TICK_LIMIT = 1000 -- CPU Ticks
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
        EXPLORER_PACKAGES = {'plenary.nvim', 'neo-tree.nvim', 'telescope-file-browser.nvim', 'telescope.nvim'}
        ,METADATA = {
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
            ,INODE = "INODE"
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
            ,ABSOLUTE_PATH = 'ABSOLUTE_PATH'
            ,URI = "URI"
            ,METADATA = 'METADATA'
        }
        ,STANDARD_METADATA_FLAGS = {
            ABSOLUTE_PATH = 'ABSOLUTE_PATH',
            BLKSIZE = "BLKSIZE",
            FIELD_TYPE = "FIELD_TYPE",
            GROUP = "GROUP",
            INODE = "INODE",
            MTIME_SEC = "MTIME_SEC",
            NAME = "NAME",
            PERMISSIONS = "PERMISSIONS",
            SIZE = "SIZE",
            TYPE = "TYPE",
            URI = "URI",
            USER = "USER",
        }
    }
    ,ui = {
        ENTRY_SCHEMA = {
            NAME = "NAME",
            STATE = "STATE",
            LAST_ACCESSED = "LAST_ACCESSED",
            URI = "URI"
        }
    }
}
