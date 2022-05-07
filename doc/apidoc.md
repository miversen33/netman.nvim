<sup>[Source can be found here](https://github.com/miversen33/netman.nvim/blob/main/doc/apidoc.md)</sup>  
The "API" of Netman consists of 4 parts. Those parts are
## [API](#api) (Redundant I know but :man_shrugging:)
## [Providers](#providers-1)
## [Options](#options-1)
## [Shims](#shimswip)

## TLDR
The [`api`](#api) is the main abstraction point within `Netman`. This component is what sits between the end user and the other components ([providers](#providers) and [shims](#shimswip)). This abstraction layer allows users to not have to worry about how to interact with the underlying [`providers`](#providers), it allows [`providers`](#providers) to not have to worry about how users will interact with the data, it allows [`shims`](#shimswip) to not have to worry about how to interface with [`providers`](#providers), etc. Everything comes and goes through the [`api`](#api).

Notable functions within the [`api`](#api) are
- [`load_provider`](#loadproviderproviderpath)
- [`read`](#readbufferindex-path)

The [`Provider`](#providers) is the bridge between the [`api`](#api) and external data sources. Examples of providers are
- [`netman.providers.ssh`](#https://github.com/miversen33/netman.nvim/blob/main/lua/netman/providers/ssh.lua)

Notable functions within a [`provider`](#providers) are
- [`read`](#readuri-cache)
- [`write`](#writebufferindex-uri-cache)

The [`Shim`](#shimswip) are the bridge between the [`api`](#api) and external file browsers. This concept is currently being explored and will likely change and grow as its experimented with.

Notable functions within a [`shim`](#shimswip) are
- [`explore`](#exploredetails)

Each of these 3 pieces have their own specification which is laid out below. For more details on how these parts interact, as well as how Netman as whole works, please checkout the [Developer Guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)

## What to expect from this documentation
Each of the above parts will have their "public facing" items documented here. "Private" functions/variables will _not_ be documented in this documentation as they are _not_ meant to be used.

Private functions/variables will usually have a `_` leading them (so for example, `_my_private_variable` or `_my_private_function`).

Note, the specification for each function below is laid out in the follow example format
```lua
function_name(param1, param2, paramX)
```
- Version Added:
- Param1
    - Type: Expected Type
    - Details: (Optional)
- Param2
    - Type: Expected Type
    - Details: (Optional)
- ParamX
    - Type: Expected Type
    - Details: (Optional)
- Returns
    - Type: Expected Return Type
    - Details: (Optional)
- Throws
    - Details about potential errors that are thrown in this function
- Notes (Optional)

# [API](https://github.com/miversen33/netman.nvim/blob/main/lua/netman/api.lua)
The [`api`](#api) is the core of `Netman` and all processing of remote data is done through the [`api`](#api). It is worth noting that the [`api`](#api) itself does not do much processing of the data, relegating that to the relevant [`provider`](#providers) to do. Instead, [`api`](#api) acts as a sort of middle man between the user and the [`provider`](#providers). [`API`](#api) is designed with the following core concepts in mind

- The [`api`](#api) should be strict
- The [`api`](#api) should be consistent
- The [`api`](#api) should make as few decisions as possible
- The [`api`](#api) should not manipulate data

With these concepts in mind, the [`api`](#api) is able to ensure a _stable_ contract between the user and [`provider`](#providers) without either having to interface much with the other.

There are 2 key variables that the [`api`](#api) revolves around, and these are
- `buffer_index`
- [`uri`](#uri)

The `buffer_index` is the lua [integer](https://www.lua.org/pil/2.3.html) representation of the `vim` buffer id that is currently being interacted with. This is used as a sort of `key` within [`api`](#api) due to the nature of `buffer_index` never changing within `vim`. This fact (that `buffer_index` is unique) makes it a prime mechanic for being the `key` in various objects within [`api`](#api)

The [`uri`](#uri) is the string representation of the remote data that the user wishes to interface with. A [`uri`](#uri) is traditionally represented in the following manner `protocol://host_authentication_information/path` and [`api`](#api) makes this assumption when dealing with [`uri`](#uri)s from the user.

The process of interfacing with the [`api`](#api) is outlined more in the [Developer Guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)

## init(core_providers)
- Version Added: 0.1
- `core_providers`
    - Type: [Array](https://www.lua.org/pil/11.1.html)
    - Details: `core_providers` is an optional array that can be provided on API initialization. If not provided, this will default to [`netman.providers`](https://github.com/miversen33/netman.nvim/blob/main/lua/netman/providers/init.lua)
- Returns: nil
- Throws
    - Errors thrown by [`load_provider`](#loadproviderproviderpath) will be thrown from this as well
- Notes
    - [`init`](#initcoreproviders) is called **automatically** on import of [`netman.api`](#api) and has a lock in place to prevent side effects of multiple imports of [`api`](#api). 
    - **This function _does not_ need to be called when importing `netman.api`**
## dump_info(output_path)
- Version Added: 0.1
- `output_path`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: `output_path` is optional and defaults to `$HOME/*random string*` where `*random string*` is a randomly generated 10 character string
- Returns: nil
- Throws: nil
- Notes
    - [`dump_info`](#dumpinfooutputpath) can be called via the `:Nmlogs` vim command and will do the following 2 things
        - Dump session related logs into the file created at `output_path` (Note: if a file exists in `output_path`, it will be **overwritten** with the dump)
        - Open this file in a new `NetmanLogs` filetype buffer for viewing
## unload(buffer_index)
- Version Added: 0.1
- `buffer_index`
    - Type: [Integer](https://www.lua.org/pil/2.3.html)
    - Details: `buffer_index` is the index of the buffer to be unloaded from the [`api`](#api)'s current state.
- Returns: nil
- Throws: nil
- Notes
    - [`unload`](#unloadbufferindex) will be called automatically when a `Netman` managed buffer is closed by vim (due to the an autocommand that is registered to [`BufUnload`](https://neovim.io/doc/user/autocmd.html#BufUnload) for the specific protocol that the buffer was opened with)
    - Unload will cleanup the local file used for a remote file pull if the provider performed a remote file pull
    - Unload will call `close_connection` on the associated provider if the provider implemented `close_connection`
## load_provider(provider_path)
- Version Added: 0.1
- `provider_path`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: `provider_path` should be the string path to import a provider. For example [`netman.provider.ssh`](https://github.com/miversen33/netman.nvim/blob/main/lua/netman/providers/ssh.lua)
- Returns: nil
- Throws
    - "Failed to initialize provider: " error
        - This is thrown when an attempt to import the provider fails or the provider has no contents (IE, its an empty file)
        - This is _also_ thrown (with different sub details) if the provider is missing one of the required attributes. For more details on  required attributes for a provider, [please consult the Developer Guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
- Notes
    - [`load_provider`](#loadproviderproviderpath) is the expected function to call when you are registering a new provider to handle a protocol, or registering an explorer to handle tree browsing. The function does a handful of things, which are laid out below
        - Attempts to import the provider. If there is a failure in the initial import, the above error(s) are thrown
        - Validates the provider has the required attributes as laid out in the [developer guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
        - Calls the provider's `init` function if it has one
        - Ensures that _core providers_ do not override 3rd party providers. This means that `Netman` will _never_ attempt to override an existing provider for a protocol that netman supports.
            - **NOTE: Netman does _not_ prevent overriding of 3rd party providers by other 3rd party providers. Netman operates providers on "most recent provider" basis. This means that the most recent provider to register as the provider for a protocol will be used**
        - Register `autocommands` that link the providers [`protocols`](#protocol) to `Netman` to be handled by the [`API`](#api)
## load_explorer(explorer_path, force)
- Version Added: 0.9
- `explorer_path`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: `explorer_path` should be the string path to import a explorer shim. For example [`netman.provider.explore_shim`](https://github.com/miversen33/netman.nvim/blob/main/lua/netman/providers/explore_shim.lua)
- `force`
    - Type: [Boolean](https://www.lua.org/pil/2.2.html)
    - Details: `force` is used to indicate if we should _force_ use of this explorer path
- Returns: nil
- Throws: 
    - "Failed to initialize explorer" error
        - This is thrown when the explorer is missing a required attribute. For more details on required explorer attributes, please consult the [developer guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
- Notes
    - [`load_explorer`](#loadexplorerexplorerpath-force) is a sub function that is called by [`load_provider`](#loadproviderproviderpath). It is advised that you call [`load_provider`](#loadproviderproviderpath) when loading _any provider_ in `Netman`, including an `explorer_shim`.
## read(buffer_index, path)
- Version Added: 0.1
- `buffer_index`
    - Type: [Integer](https://www.lua.org/pil/2.3.html)
    - Details: **Required** Index of the buffer to associate the uri with, stored within [`api`](#api) and used as the key to access state objects associated with the buffer. If nil (but provided), [`api`](#api) delays association until the `URI` is claimed later. For more details on this process, please consult the [developer guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
- `path`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The [`URI`](#uri) to open. This is passed directly to the associated provider for this [`URI`](#uri)
- Returns
    - [`read`](#readbufferindex-path) returns 1 of the following 2 items, depending on what the [`provider`](#provider) declares the return type should be on read
        - nil
            - This is usually returned if the provider determined that it needs to interface with a [`File Manager`](#file-manager), though it can also be returned if [`read`](#readbufferindex-path) throws an error (see below)
        - command
            - This is a command that is generated by [`api`](#api) to be used by `vim` to display the contents for the user to interface with.
- Throws
    - Any errors that the [`provider`](#provider) may throw during its `read` operation
    - "Unable to figure out how to display: " error
        - An invalid return type was provided to [`read`](#readbufferindex-path) from the [`provider`](#provider)'s `read` operation
    - "No tree explorer loaded" error
        - The [`provider`](#provider) attempted to load an explorer when one wasn't available to load
- Notes
    - [`read`](#readbufferindex-path) is accessible via the `:Nmread` command which is made available by `netman.init`. It is also automatically called on [`FileReadCmd`](https://neovim.io/doc/user/autocmd.html#FileReadCmd) and [`BufReadCmd`](https://neovim.io/doc/user/autocmd.html#BufRead) `vim` events. The end user should _not_ have to directly interface with `netman.api.read`, instead preferring to let `vim` handle that via the above listed events.
    - Read operates on a generate-and-reserve model where it generates buffer details (via calls to the associated [`provider`](#provider)) and then depending on results from the provider it will either claim the buffer details immediately or wait for the [`provider`](#provider) to inform it that it is safe to do so. This is especially useful when opening multiple files via different providers as [`api`](#api) will not conflict with itself trying to organize buffers to buffer objects while juggling the various (potentially asynchronous) providers
    - [`read`](#readbufferindex-path) expects a return of 1 of 3 well defined types from the [`provider`](#provider)s [`read`](#readbufferindex-path) function, which are detailed more below. These types are
        - [READ_TYPE.FILE](#read-type-file)
            - If [`read`](#readbufferindex-path) is returned a [`READ_TYPE.FILE`](#read-type-file), it will assume that the information being read into the `vim` buffer is a local file. [`api`](#api) will document this and remember to clean up this local file after [`unload`](#unloadbufferindex) is called
        - [READ_TYPE.STREAM](#read_type_stream)
        - [READ_TYPE.EXPLORE](#read-type-explore)
## delete(delete_path)
- Version Added: 0.1
- `delete_path`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string [`URI`](#uri) to delete.
- Returns: nil
- Throws
    - "Unable to delete: " error
        - Thrown if a viable provider was unable to be found for `delete_path`
    - Any errors that the [`provider`](#provider) throws during the [`delete`](#deletedeletepath) process
- Notes
    - [`delete`](#deletedeletepath) does **_not_** require the URI to be a loaded buffer, _however_ it does require a provider be loaded (via [`load_provider`](#loadproviderproviderpath)) that can handle the protocol of the [`URI`](#uri) that is being requested to delete
    - [`delete`](#deletedeletepath) is available to be called via the `:Nmdelete` vim command
## write(buffer_index, write_path)
- Version Added: 0.1
- `buffer_index`
    - Type: [Integer](https://www.lua.org/pil/2.3.html)
    - Details: The buffer index associated with the write path
- `write_path`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string [`URI`](#uri) to create
- Returns: nil
- Throws
    - Any errors that the [`provider`](#provider) throws during the [`write`](#writebufferindex-writepath) process
- Notes
    - [`write`](#writebufferindex-writepath) does an asynchronous call to the [`provider`](#provider)'s `write` method and then immediately returns back so the user can continue working. **DO NOT EXPECT THIS TO BLOCK**
    - [`write`](#writebufferindex-writepath) is available to be called via the `:Nmwrite` vim command
## get_metadata(requested_metadata)
- Version Added: 0.95
- `requested_metadata`
    - Type: [Array](https://www.lua.org/pil/11.1.html)
    - Details: `requested_metadata` should be an array of [valid METADATA](https://github.com/miversen33/netman.nvim/blob/main/lua/netman/options.lua) options
- Returns
    - `key`, `value` pairs table where the key is each item in `requested_metadata` and the `value` is what was returned by the provider
- Throws: nil
- Notes
    - This will be called by the explorer shim whenever an explorer requests [`libuv`](https://github.com/luvit/luv/blob/master/docs.md#uvfs_statpath-callback) details about a remote location. `Netman` will reach down to the provider for the remote location and call the same named function ([`get_metadata`](#getmetadatauri-requestedmetadata)).
## version
- Version Added: 0.1
- Notes
    - It's a version tag, what notes do you need?
## unload_provider(provider_path)
- Version Added: 0.95
-  `provider_path`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string path for the provider to unload
- Returns: nil
- Throws: nil
- Notes
    - This function is provided strictly for development use and is **not** required to be called in the lifecycle of a provider. 
    - Use cases for this function are mostly when working on a new provider. By calling this function, you will remove the provider
        **both from `Netman's` memory as well as `lua` as a whole
    - Targeted use is live development of a provider without having to restart Neovim.
    - See Also [reload_provider](#reloadproviderproviderpath)

## reload_provider(provider_path)
- Version Added: 0.95
- `provider_path`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string path for the provider to reload
- Returns: nil
- Throws
    - Any errors that [load_provider](#loadproviderproviderpath) throws
- Notes
    - This is a helper function that simply calls [unload_provider](#unloadproviderproviderpath) followed immediately by [load_provider](#loadproviderproviderpath)
# Providers
A [`provider`](#providers) is a program (`Neovim` plugin in the case of `Netman`) that acts as a middle man between [`api`](#api) and external programs. The [`providers`](#providers) job is to communicate with said external programs and return consistently formatted data to the [`api`](#api) so it can be returned to the user to be handled.

An example of a provider is [`netman.providers.ssh`](https://github.com/miversen33/netman.nvim/blob/main/lua/netman/providers/ssh.lua)
When creating a provider, there are several key things to keep in mind.
[`api`](#api) chooses which provider to use for a given [`uri`](#uri) based on the [`provider`](#providers) `protocol_patterns`. These patterns are extracted and analyzed when a [`provider`](#providers) registers itself with the [`api`](#api) on its [`load_provider`](#loadproviderproviderpath) call (**which is required in order to have your [`provider`](#providers) be made available to consume [`uri`](#uri)s from the user**)

There are several required attributes a provider must implement, those being
- [`read`](#readuri-cache)
- [`write`](#writebufferindex-uri-cache)
- [`delete`](#deleteuri-cache)
- [`get_metadata`](#getmetadatarequestedmetadata)
- [`name`](#name)
- [`protocol_patterns`](#protocolpatterns)
- [`version`](#version-1)

There are additional optional attributes that if implemented, will be called during the lifecycle of the provider and buffers associated with it. Those being
- [`init`](#initconfigurationoptions)
- [`close_connection`](#closeconnectionbufferindex-uri-cache)

There are 2 key variables that are provided with most calls to a [`provider`](#providers) by the [`api`](#api). Those are
- [`uri`](#uri)
- `cache`

The [`uri`](#uri) is the string representation of the remote data that the user wishes to interface with. A [`uri`](#uri) is traditionally represented in the following manner `protocol://host_authentication_information/path` and [`api`](#api) uses this assumption to determine if a [`provider`](#providers) should handle that [`uri`](#uri) or not. 

The `cache` object is a `table` that is created (as an empty table) by [`api`](#api) after calling the [`provider's`](#providers) [`init`](#initconfigurationoptions) function. This is a safe place for the [`provider`](#providers) to store `state` as it is not manipulated by anything else (including the [`api`](#api), other [`providers`](#providers), etc) and stores any changes made to it by the [`provider`](#providers). This is especially useful when establishing the initial details from the [`uri`](#uri) so the [`provider`](#providers) doesn't have to continually re-parse a [`uri`](#uri)

Details on how to implement a [`provider`](#providers) can be found within the [Developer Guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
## read(uri, cache)
- Version Added: 0.1
- [`uri`](#uri)
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string [`URI`](#uri) to read
- `cache`
    - Type: [Table](https://www.lua.org/pil/2.5.html)
    - Details: The `table` object that is stored and managed by the [`api`](#api). The `api` gets this object from the [`provider`](#provider)'s [`init`](). For more details on how the cache works, consult the [Developer Guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
- Returns
    - [`read`](#readuri-cache) must return one of the 4 following items
        - A table containing the following `key`, `value` pairs, and [`READ_TYPE.FILE`](#read-type-file)
            - local_path: String to file path to load
            - origin_path: String for the original URI of the file
            - unique_name: (Optional) String to indicate what the "unique" name of this file is
        - An array containing strings to be displayed in the buffer, and [`READ_TYPE.STREAM`](#read-type-stream)
            - It is assumed that each entry in the array is 1 "line" to be displayed in the buffer. Conform to this assumption in order to use [`READ_TYPE.STREAM`](#read-type-stream)
        - A table containing the following `key`, `value` pairs, and [`READ_TYPE.EXPLORE`](#read-type-explore)
            - parent: Integer pointing to the location in `details` that is the parent object
            - details: An array of table objects where each table contains the following `key`, `value` (at minimum) pairs
                - `FIELD_TYPE`: String
                - `NAME`: String
                - `URI`: String
        - nil
        - For more information on how the [`read`](#readuri-cache) process works, please consult the [`Developer Guide`](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
- Throws
    - It is acceptable to throw any errors that are encountered in the process of opening the requested URI
- Notes
    - [`read`](#readuri-cache) is a `synchronous` operation, meaning [`api`](#api) will block and wait for _some_ result on read. This can be partially circumvented by returning `nil` and then calling `netman.api.read` at a later point with the same [`URI`](#uri) details as provided earlier. This is useful if the provider has to do some backend work before it can "read" the URI properly (IE, needs to get a password from the user, must register an endpoint, must create a container, etc). More details on the `read` process can be found in the [`Developer Guide`](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
## write(buffer_index, uri, cache)
- Version Added: 0.1
- `buffer_index`
    - Type: [Integer](https://www.lua.org/pil/2.3.html)
    - Details: The buffer index associated with the write path
- `uri`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string [`URI`](#uri) to create
- `cache`
    - Type: [Table](https://www.lua.org/pil/2.5.html)
    - Details: The `table` object that is stored and managed by the [`api`](#api). The `api` gets this object from the [`provider`](#provider)'s [`init`](). For more details on how the cache works, consult the [Developer Guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
- Returns: nil
- Throws
    - It is acceptable to throw any errors that are encountered in the process of writing the requested [`URI`](#uri)
- Notes
    - [`api`](#api) does not currently provide any tools for dealing with oddities in the write process (permission error, network failure, etc), and those errors and validations are left up to the provider to handle.
    - **NOTE: [`api`](#api) calls the [`write`](#writebufferindex-uri-cache) function asynchronously and thus the provider cannot expect the [`api`](#api) to block on it. The provider should get whatever details it will need for the write immediately before doing any long running tasks as those resources may change over time**
## delete(uri)
- Version Added: 0.1
- `uri`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string [`URI`](#uri) to delete
- Returns: nil
- Throws
    - It is acceptable to throw any errors that are encountered in the process of delete the requested [`URI`](#uri)
- Notes
    - [`api`](#api) does not currently provide any tools for dealing with oddities in the delete process (user verification, permission error, network failure, etc), and those errors and validations are left up to the provider to handle.
    - **NOTE: [`api`](#api) calls the [`delete`](#deleteuri-cache) function asynchronously and thus the provider cannot expect the [`api`](#api) to block on it. The provider should get whatever details it will need for the delete immediately before doing any long running tasks as those resources may change over time**
## get_metadata(uri, requested_metadata)
- Version Added: 0.95
- `uri`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string [`URI`](#uri) to get metadata for
- `requested_metadata`
    - Type: [Array](https://www.lua.org/pil/11.1.html)
    - Details: `requested_metadata` will be a `key`, `value` table where the `key` a valid [METADATA](#options-1) option
- Returns
    - Should return a [`Table`]()
- Throws: nil
- Notes
    - This will be called by [`api`](#api) whenever the user requests additional metadata about a link/destination. The `keys` are all valid [`stat` flags](https://man7.org/linux/man-pages/man2/lstat.2.html) and [`api`](#api) will expect the data returned to conform to the datatypes that `stat` will return for those flags
## init(configuration_options)
- Version Added: 0.1
- `configuration_options`
    - Type: [Table](http://www.lua.org/pil/2.4.html)
    - Details: WIP (currently unused)
- Returns
    - Should return a `true`/`false` depending on if the provider was able to properly initialize itself
- Throws: nil
- Notes
    - **[`init`](#initconfigurationoptions) is an optional function that will be called immediately after import of the [`provider`](#providers) if it exists**
    - This function's intended purpose is to allow the [`provider`](#providers) to verify that the environment it is being ran in is capable of handling it (IE, the environment meets whatever requirements the [`provider`](#provider) has), though it can be used for whatever the [`provider`](#providers) need in order to ensure it is ready to run
## close_connection(buffer_index, uri, cache)
- Version Added: 0.1
- `buffer_index`
    - Type: [Integer](https://www.lua.org/pil/2.3.html)
    - Details: The buffer index associated with the write path
- `uri`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string [`URI`](#uri) to create
- `cache`
    - Type: [Table](https://www.lua.org/pil/2.5.html)
    - Details: The `table` object that is stored and managed by the [`api`](#api). The `api` gets this object from the [`provider`](#provider)'s [`init`](). For more details on how the cache works, consult the [Developer Guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
- Returns: nil
- Throws: nil
- Notes
    - **[`close_connection`](#closeconnectionbufferindex-uri-cache) is an optional function that will be called immediately after a `BufUnload` event if called from `vim`, if [`close_connection`](#closeconnectionbufferindex-uri-cache) exists on the provider**
    - This function's intended purpose is to allow the [`provider`](#providers) to clean up after a buffer has been closed. The intent being to allow the [`provider`](#providers) a way to close out existing connections to remote locations, close files, etc
## name
- Version Added: 0.1
- Notes: The string name of the provider
## protocol_patterns
- Version Added: 0.1
- Notes
    - [`protocol_patterns`](#protocolpatterns) should be an array of the various protocols (**not blobs**) that the provider supports. 
    - **NOTE: [`protocol_patterns`](#protocolpatterns) is sanitized on read in by [`api`](#api)
## version
- Version Added: 0.1
- Notes
    - You've come far in the documentation. I am proud of you :)

# Options
Options can be found in `netman.options`. These "options" are a table which acts as a sort of enum for the core of `Netman`. `api` relies on these options as a standard way of communicating "information" between itself and its providers. Below is a breakdown of each "option" that can be found here. These options will be referenced throughout various points in the [`API Documentation`](https://github.com/miversen33/netman.nvim/wiki/API-Documentation) as well as the [`Developer Guide`](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
- utils
    - command
        - IGNORE_WHITESPACE_ERROR_LINES
        - IGNORE_WHITESPACE_OUTPUT_LINES
        - STDOUT_JOIN
        - STDERR_JOIN
        - SHELL_ESCAPE
- api
    - READ_TYPE
        - FILE
        - STREAM
        - EXPLORE
    - ATTRIBUTES
        - FILE
        - DIRECTORY
        - LINK
    - protocol
        - EXPLORE
    - explorer
        - METADATA
            - PERMISSIONS
            - OWNER_USER
            - OWNER_GROUP
            - SIZE_LABEL
            - SIZE
            - GROUP
            - PARENT
            - FIELD_TYPE
            - TYPE
            - INODE
            - LASTACCESS
            - FULLNAME
            - URI
            - NAME
            - LINK
            - DESTINATION
        - FIELDS
            - FIELD_TYPE
            - NAME
            - URI
# Shims(WIP)
## explore(details)
- Version Added: 0.9
- `details`
    - Type: [Table](https://www.lua.org/pil/2.5.html)
    - Details: The explore object will contain the a table with the following `key`, `value` pairs
        - parent: Integer pointing to the location in `details` that is the parent object
        - details: An array of table objects where each table contains the following `key`, `value` pairs
            - `FIELD_TYPE`: String
            - `NAME`: String
            - `URI`: String
- Returns: nil
- Throws: nil
- Notes
    - [`explore`](#exploredetails) is the method that [`api`](#api) will call when it is reaching out to the explorer to feed it with contents to display. 
    - [`explore`](#exploredetails) should reach out to its associated [`File Manager`](#file-manager) and feed it the provided details in `details`.`details` in a way the [`File Manager`](#file-manager) understands
## protocol_patterns
- Version Added: 0.9
- Notes
    - [`protocol_patterns`](#protocolpatterns) should be simply `netman.options.protocol.EXPLORE`. Anything else will cause the [`shim`](#exploredetails) to not be recognized as a valid [`explore_shim`](#shim)
## version
- Version Added: 0.9
- Notes
    - I'm tired, I am running out of quirky things to say here
---

# Glossary
## File Manager: 
A program that is used to visualize a directory tree
## Protocol:
Term used to indicate method of network communication to use. EG: `ssh`, `rsync`, `ftp`, etc
## Provider: 
Program that integrates with `Netman` to provide a bridge between a program that supports a [protocol](#protocol) and `vim`
## URI: 
A string representation of a path to a stream/file. EG: `sftp://host/file` or `ftp://ip_address/file`. A more technical definition can be found [on wikipedia](https://en.wikipedia.org/wiki/Uniform_Resource_Identifier)
## Shim: 
A program that acts as a "wedge" or "shim" between 2 programs. Usually used to modify the input/output between the 2 programs