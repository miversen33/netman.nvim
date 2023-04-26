<sup>[Source can be found here](https://github.com/miversen33/netman.nvim/blob/main/doc/apidoc.md)</sup>  
The "API" of Netman consists of 4 parts. Those parts are
## [API](#api) (Redundant I know but :man_shrugging:)
## [Providers](#providers-1)
## [Consumers](#consumers)
## [Options](#options-1)

## TLDR
The [`api`](#api) is the main abstraction point within `Netman`. This component is what sits between the end user, the [providers](#providers) and [consumers](#consumers). This abstraction layer allows users to not have to worry about how to interact with the underlying [`providers`](#providers), it allows [`providers`](#providers) to not have to worry about how users will interact with the data, it allows [`consumers`](#consumers) to not have to worry about how to interface with [`providers`](#providers), etc. Everything comes and goes through the [`api`](#api).

Notable functions within the [`api`](#api) are
- [`load_provider`](#loadproviderproviderpath)
- [`read`](#readbufferindex-path)

The [`Provider`](#providers) is the bridge between the [`api`](#api) and external data sources. Examples of providers are
- [`netman.providers.ssh`](https://github.com/miversen33/netman.nvim/blob/main/lua/netman/providers/ssh.lua)
- [`netman.providers.docker`](https://github.com/miversen33/netman.nvim/blob/main/lua/netman/providers/docker.lua)

Notable functions within a [`provider`](#providers) are
- [`read`](#readuri-cache)
- [`write`](#writebufferindex-uri-cache)

The [`Consumer`](#consumers) is the bridge between the [`api`](#api) and external file browsers.

Each of these 3 pieces have their own specification which is laid out below. For more details on how these parts interact, as well as how Netman as whole works, please checkout the [Developer Guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)

## What to expect from this documentation
Each of the above parts will have their "public facing" items documented here. "Private" functions/variables will _not_ be documented in this documentation as they are _not_ meant to be used.

Private functions/variables will usually have a `_` leading them (so for example, `_my_private_variable` or `_my_private_function`), or be a member of an `internal` attribute (so for example, `internal.my_private_function`)

Note, the specification for each function below is laid out in the follow example format
```lua
function_name(param1, param2, paramX)
```
- Version Added:
- Updated      :
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

Most communication with the api will revolve around "uris". A [`uri`](#uri) is the string representation of the remote data that the user wishes to interface with. A [`uri`](#uri) is traditionally represented in the following manner `protocol://host_authentication_information/path` and [`api`](#api) makes this assumption when dealing with any uris from the user.

The process of interfacing with the [`api`](#api) is outlined more in the [Developer Guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)

## process_handle
- Version Added: 1.02
- Returns: table
- Notes  
    A process handle is a table that is returned by the API whenever a successful async operation has began with the provider. These handles are always returned in place of the "expected" output of a function. The handle contains the following key/value pairs
    - `async`: boolean
        - A boolean to indicate if the process is indeed asynchronous. This handle will always have this set to `true`, though
        this value will also be returned by anything within the api where async is an option (and set to false accordingly).
        - If this is true, you can assume that   
            a) The requested process is indeed running asynchronously  
            b) That you received an `process_handle`
    - `read`: function(pipe)
        - A function that will attempt to read from the process's underlying stdout/stderr pipe
        - Note: this will be talking to the underlying [`netman.shell.async_handler`](https://github.com/miversen33/netman.nvim/tree/main/lua/netman/tools/utils#L93-L186) directly
        - `pipe` (optional)
            - A string that should be either `STDOUT` or `STDERR` to indicate which pipe you wish to read from
        - Returns: table
            - Returns a table of strings (may be empty if there is no output)
    - `write`: function(data)
        - A function that will attempt to write to the process's underlying stdin pipe
        - Note: this will be talking to the underlying [`netman.shell.async_handler`](https://github.com/miversen33/netman.nvim/tree/main/lua/netman/tools/utils#L93-L186) directly
        - `data` string
            - A string of what you wish to write to stdin
        - Returns: table
            - Returns a table of strings (may be empty if there is no output)
    - `stop`: function(force)
        - A function that will attempt to stop to the underlying process
        - Note: this will be talking to the underlying [`netman.shell.async_handler`](https://github.com/miversen33/netman.nvim/tree/main/lua/netman/tools/utils#L93-L186) directly
        - `force` boolean
            - A boolean to indicate if you wish for the process to be uncleanly (forced) killed  

    If an async handle is returned, the callback will be called whenever the API receives information to provide to it. The parameter for these calls will be as follows. You may notice that all attributes are optional. This means that a callback can get any combination of these, however callback will _never_ be called with nothing. There will always be one or more of the below attributes in the parameter passed to it.
    - `success`: boolean (optional)
        - A boolean to indicate if the process completed successfully or not
        - *This will be called when the process is complete and only when the process is complete*
    - `data`: table (optional)
        - A table containing data that matches the "return data" that you expected from the function you called. 
    - `message`: table (optional)
        - A table that can be provided to indicate there is some message to relay to the end user. It can have the following keys
        - `message`: string
            - The message to relay to the user
        - `retry`: boolean|function (optional)
            - If provided, this will either be a boolean or a function. If its a boolean, it indicates that you should try calling whatever
            you called before again. If its a function, it expects the user input from the message to be provided to it so it can continue
            processing whatever it was doing.

## init()
- Version Added: 0.1
- Updated      : 1.01
- Returns: nil
- Throws
    - Errors thrown by [`load_provider`](#loadproviderproviderpath) will be thrown from this as well
- Notes
    - [`init`](#initcoreproviders) is called **automatically** on import of [`netman.api`](#api) and has a lock in place to prevent side effects of multiple imports of [`api`](#api).
    - **This function _does not_ need to be called when importing `netman.api`**

## unload_buffer(buffer_index)
- Version Added: 0.1
- Updated      : 1.01
- `uri`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string URI associated with the unloaded buffer
- Returns: nil
- Throws: nil
- Notes
    - [`unload_buffer`](#unload_bufferbuffer_index) will be called automatically when a `Netman` managed buffer is closed by vim (due to the an autocommand that is registered to [`BufUnload`](https://neovim.io/doc/user/autocmd.html#BufUnload) for the specific protocol that the buffer was opened with)
    - [`unload_buffer`](#unload_bufferbuffer_index) will cleanup the local file used for a remote file pull if the provider performed a remote file pull
    - Unload_buffer will call |close_connection| on the associated provider if the provider implemented [`close_connection`](#close_connectionbuffer_index-uri-cache)
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

## read(uri, opts, callback)
- Version Added: 0.1
- Updated      : 1.02
- `uri`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The uri to open. This is passed directly to the associated provider for this uri
- `opts`
    - Type: Table
    - Details: Table containing read options. Valid options are
        - force: boolean
            - If provided, we will remove any cached version of the uri and call the provider to re-read the uri
    - `callback`
        - Type: function (optional)
        - Details: A function to call during the processing of `read`. Any data that would be returned will instead be streamed 
        - NOTE: Providing a callback indicates to the API that you want the process to run asynchronously. This will change your output 
        to a [netman.api.process_handle](#process_handle) (unless async fails. Detailed in the [netman.api.process_handle](#process_handle))
- Returns
    - NOTE: If this is being called asynchronously (via the `callback` parameter), these results may be streamed to the callback instead. See [netman.api.process_handle](#process_handle) for details on this process
    - [`read`](#readuri-opts) returns a table that will have the following key/value pairs (some
      are optional)
        - success: boolean
            - A boolean to indicate if the provider successfully read the uri
        - error: table (optional)
            - If provided, a message to be relayed to the user, usually given
              by the provider. Should be a table that has a single attribute
              (message) within. An example
              > {error = { message = "Something bad happened!"}}
        - type: [String](http://www.lua.org/pil/2.4.html)
            - Will be one of the following strings
              - STREAM, EXPLORE, FILE
                These are enums found in netman.options.api.READ_TYPE
        - data: table (optional)
            - If provided, the data that was read. This will be a table,
              though the contents will be based on what type is returned
            - Type EXPLORE:
                - A 1 dimensional array where each item in the array contains
                  the following keys
                    - ABSOLUTE_PATH: table
                      - A piece by piece break down of the path to follow to
                        reach the item in question. As an example, for 
                        `sftp://myhost///my/dir/`, this would return >
                            {
                                name = 'my',
                                uri = "sftp://myhost///my"
                            },
                            {
                            name = "dir",
                                uri = "sftp://myhost///my/dir"
                            }
                        <
                    - FIELD_TYPE: string
                        - This will be either `LINK` or `DESTINATION`
                          For a traditional filesystem, accept `LINK`
                          as a "directory" and `DESTINATION` as a "file"
                    - METADATA: table
                        - Whatever (`stat` compatible) metadata the provider
                          felt like providing with the item in question
                    - NAME: string
                        - The "relative" name of the item. As an example:
                          `sftp://myhost///my/dir` would have a name of `dir`
                    - URI: string
                        - The "absolute" uri that can be followed to 
                          reach the item in question. This is more useful for
                          LINK navigation (tree walking) as directories may be
                          linked or nonexistent at times and this URI 
                          should ensure access to the same node at all times
        - Type FILE:
            - A table containing the following key/value pairs (or nil)
                - data: table
                    - remote_path: string
                        - The remote absolute path to follow for this URI
                    - local_path: string
                        - The local absolute path to follow for this URI
                - error: table (Optional)
                    - TODO
        - Type STREAM:
            - A 1 dimensional table with text (each item should be considered
              a line) to display to the buffer
Notes
    - read is accessible via the `:Nmread` command which is made available by `netman.init`. It is also automatically called on `FileReadCmd` and `BufReadCmd` vim events. The end user should _not_ have to directly interface with `netman.api.read`, instead preferring to let vim handle that via the above listed events.

## delete(uri, callback)
- Version Added: 0.1
- Updated      : 1.02
- `uri`
  - Type: [String](http://www.lua.org/pil/2.4.html)
  - Details: The string [`URI`](#uri) to delete.
- `callback`
  - Type: function (optional)
  - Details: A function to call during the processing of `delete`. 
  - NOTE: Providing a callback indicates to the API that you want the process to run asynchronously. This will change your output 
        to a [netman.api.process_handle](#process_handle) (unless async fails. Detailed in the [netman.api.process_handle](#process_handle))
- Returns: nil
- Throws
    - "Unable to delete: " error
        - Thrown if a viable provider was unable to be found for `uri`
    - Any errors that the [`provider`](#provider) throws during the [`delete`](#deleteuri) process
- Notes
  -  [`delete`](#deleteuri) does **_not_** require the URI to be a loaded buffer, _however_ it does require a provider be loaded (via load_provider that can handle the protocol of the URI that is being requested to delete
    - [`delete`](#deleteuri) is available to be called via the `:Nmdelete` vim command
    - [`delete`](#deleteuri) does **_not_** require the URI to be a loaded buffer, _however_ it does require a provider be loaded (via [`load_provider`](#loadproviderproviderpath)) that can handle the protocol of the [`URI`](#uri) that is being requested to delete

## write(buffer_index, uri, opts, callback)
- Version Added: 0.1
- Updated      : 1.02
- `buffer_index` (optional)
    - Type: [Integer](https://www.lua.org/pil/2.3.html)
    - Details: The buffer index associated with the write path. If provided, we will use the index to pull the buffer content and provide that to the provider. Otherwise, the provider will be given an empty array to write out to the file NOTE: this will almost certainly be destructive, be sure you know what you are doing if you are sending an empty write!
- `uri`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string [`URI`](#uri) to create
- `opts`
  - Type: Table
  - Details: Reserved for later use
- `callback`
  - Type: function (optional)
  - Details: A function to call during the processing of `write`. 
  - NOTE: Providing a callback indicates to the API that you want the process to run asynchronously. This will change your output 
        to a [netman.api.process_handle](#process_handle) (unless async fails. Detailed in the [netman.api.process_handle](#process_handle))
- Returns: Table
    - NOTE: If this is being called asynchronously (via the `callback` parameter), these results may be streamed to the callback instead. See [netman.api.process_handle](#process_handle) for details on this process
  - A table that contains the following key/value pairs
        - success: boolean
            A boolean indicating if the provider was successful in its write
        - uri: string
            A string of the path to the uri
- Throws
    - Any errors that the [`provider`](#provider) throws during the [`write`](#writebufferindex-writepath) process
- Notes
    - [`write`](#writebufferindex-writepath) is available to be called via the `:Nmwrite` vim command

## rename(old_uri, new_uri, callback)
- Version Added: 1.01
- Updated      : 1.02
- `old_uri`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The (current) uri path to rename
- `new_uri`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The (new) uri path. The path to rename _to_
- `callback`
  - Type: function (optional)
  - Details: A function to call during the processing of `rename`. 
  - NOTE: Providing a callback indicates to the API that you want the process to run asynchronously. This will change your output 
        to a [netman.api.process_handle](#process_handle) (unless async fails. Detailed in the [netman.api.process_handle](#process_handle))
Returns: Table
    - NOTE: If this is being called asynchronously (via the `callback` parameter), these results may be streamed to the callback instead. See [netman.api.process_handle](#process_handle) for details on this process
    Returns a table that contains the following key/value pairs
        - success: boolean
            A boolean indicating if the provider was successful in its write
        - message: table (Optional)
            - If provided, a message to be relayed to the user, usually given
              by the provider. Should be a table that has a single attribute
              (message) within. An example
              > {message = { message = "Something bad happened!"}}
Notes
    - The [`api`](#api) will prevent rename from "functioning" if the **old_uri** and
      **new_uri** do not share the same provider.

## copy(uris, target_uri, opts, callback)
- Version Added: 1.01
- Updated      : 1.02
- `uris`
    - Type: table
    - Details: The table of string URIs to copy
- `target_uri`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string location to move the URIs to. Consider this a
        "parent" location to copy into
- `callback`
  - Type: function (optional)
  - Details: A function to call during the processing of `copy`. 
  - NOTE: Providing a callback indicates to the API that you want the process to run asynchronously. This will change your output 
        to a [netman.api.process_handle](#process_handle) (unless async fails. Detailed in the [netman.api.process_handle](#process_handle))
- `opts`
    - Type: table
    - Details: A table of options that can be provided to the provider.
      Valid options are
      - cleanup: boolean
          If provided, indicates to the provider that they should "clean"
          (remove) the originating file after copy is complete. Consider
          this the "move" option
- Returns: table
    - NOTE: If this is being called asynchronously (via the `callback` parameter), these results may be streamed to the callback instead. See [netman.api.process_handle](#process_handle) for details on this process
    - Details
        - A table should be returned with the following key/value pairs
          (**some are optional**)
            - success: boolean
                - This should be a true or false to indicate if the
                    copy was successful or not
            - error: table (optional)
                - This should be provided in the event that you have an
                  error to pass to the caller. The contents of this should
                  be a table with a single `message` attribute (which houses a string)
                    EG: `error = { message = "SOMETHING CATASTROPHIC HAPPENED!" }`

## move(uris, target_uri, opts)
- Version Added: 1.01
- Updated      : 1.02
See [`copy`](#copyuris-target_uri-cache---table) as this definition is the exact same (with the exception being that it tells copy to clean up after its complete)

## get_metadata(uri, metadata_keys, callback)
- Version Added: 0.95
- Updated      : 1.01
- `uri`
  - Type: [String](http://www.lua.org/pil/2.4.html)
  - Details: The uri to request metadata for
- `metadata_keys`
    - Type: Table
    - Details: A 1 dimensional table of metadata keys as found in [netman.options.metadata](#options)
- `callback`
  - Type: function (optional)
  - Details: A function to call during the processing of `get_metadata`. 
  - NOTE: Providing a callback indicates to the API that you want the process to run asynchronously. This will change your output 
        to a [netman.api.process_handle](#process_handle) (unless async fails. Detailed in the [netman.api.process_handle](#process_handle))
- Returns
    - NOTE: If this is being called asynchronously (via the `callback` parameter), these results may be streamed to the callback instead. See [netman.api.process_handle](#process_handle) for details on this process
    - `key`, `value` pairs table where the key is each item in `metadata_keys` and the `value` is what was returned by the provider

## version
- Version Added: 0.1
- Notes
    - It's a version tag, what notes do you need?

## unload_provider(provider_path, justification)
- Version Added: 0.95
- Updated      : 1.01
-  `provider_path`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string path for the provider to unload
- `justification`
    - Type: table (optional)
        - Details:
            If provided, this table should indicate why the provider is being unloaded from netman. Required keys (if the table is provided) are
            - reason: string
            - name: string
              The "require" path of the provider
            - protocol: string
              A comma delimited list of the protocols the provider supported
            - version: string
              The version of the provider
- Returns: nil
- Throws: nil
- Notes
    - This function is provided strictly for development use and is **not** required to be called in the lifecycle of a provider.
    - Use cases for this function are mostly when working on a new provider. By calling this function, you will remove the provider
        **both from `Netman's` memory as well as `lua` as a whole
    - Targeted use is live development of a provider without having to restart Neovim.

## reload_provider(provider_path)
- Version Added: 0.95
- `provider_path`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string path for the provider to reload
- Returns: nil
- Throws
    - Any errors that [load_provider](#loadproviderproviderpath) throws
- Notes
    - This is a helper function that simply calls [unload_provider](#unloadproviderproviderpath) followed immediately by [load_provider](#load_providerprovider_path)

## get_provider_logger()
- Version Added: 1.01
- Returns: table
    - Type: table
    - Details: Returns a logger object that will log out to the provider
          logs (located at `$XDG_DATA_HOME/netman/logs/provider`)

## get_consumer_logger()
- Version Added: 1.01
- Returns: table
    - Type: table
    - Details: Returns a logger object that will log out to the provider
          logs (located at `$XDG_DATA_HOME/netman/logs/consumer`)

## get_system_logger()
- Version Added: 1.01
- Returns: table
    - Type: table
    - Details: Returns a logger object that will log out to the provider
          logs (located at `$XDG_DATA_HOME/netman/logs/system`)

## clear_unused_configs(assume_yes)
- Version Added: 1.01
- `assume_yes`
    - Type: boolean
    - Default: false
    - Details: If provided, no questions are asked to the end user and
        we will just remove purge any unused configurations.
        If not provided, we will prompt for each configuration that needs
        to be removed
- Returns: nil

## generate_log(output_path)
- Version Added: 1.01
- `output_path`
  - Type: string
  - Default: nil
  - Details: If provided, the session logs that are "generated" (more like
    gathered but whatever) will be saved into this file.
- Returns: nil
- Note
    - This is one of the only functions in the api that interacts with vim's
      buffers. It will open a new buffer and set the contents of the buffer to
      the log gathered for the current session. This is very useful if you are
      trying to track down an odd event as the in memory logs are _not_
      filtered out

## register_event_callback(event, callback)
- Version Added: 1.01
- `event`
    - Type: string
    - Details: An event to listen for
- `callback`
    - Type: function
    - Details: The callback to be called when the event is emitted.
        When this function is called by the API, it will be provided with
        a table that contains the following key/value pairs
            - event: string
              - The event that was fired
            - source: string (optional)
              - The source that emitted the event. This is not required by
                [`emit_event`](#emit_eventevent-source) and thus may be nil
- Returns: `id`
    - An id that is used to associated the provided callback with the event
- Throws
    - `INVALID_EVENT_ERROR`
      - An error that is thrown if the requested event is nil
    - `INVALID_EVENT_CALLBACK_ERROR`
      - An error that is thrown if there is no callback provided

## unregister_event_callback(id)
- Version Added: 1.01
- `id`
    - Type: string
    - Details: The id of the callback to unregister. This id is provided
      by |netman.api.register_event_callback|
- Returns: nil
- Throws
    - `INVALID_ID_ERROR`
      - An error that is thrown if the id is nil

## emit_event(event, source)
- Version Added: 1.01
- `event`
    - Type: string
    - Details: The event to emit (I know, super clever!)
- `source`
    - Type: string (optional)
    - Details: The name of the caller. Usually this would be the require
      path of the caller but you can technically use whatever you want
      here
- Returns: nil
- Note:
    - This is (currently) a synchronous call, so your callback needs to
      process the event quickly as it _will_ hold up the rest of neovim

## provider.get_providers()
- Version Added: 1.02
- Returns: table
    - A 1 dimensional table with the path to each provider currently active in Netman
- Note:
    - This is intended to be used by consumers to show the currently active providers
    within Netman. This path can be used to pull the module and extract UI information
    from it. Details on the valid UI elements a provider can return can be found in
    [Provider UI Table]()

## provider.get_hosts(provider)
- Version Added: 1.02
- `provider`
    - Type: string
    - Details: The path to the provider. This can be retrieved via [provider.get_providers](#providerget_providers)
- Returns: table
    - A 1 dimensional table containing strings with the name of each host the
    provider knows about

## provider.get_host_details(provider, host)
- Version Added: 1.02
- `provider`
    - Type: string
    - Details: The string path to the provider. Retrieved via [provider.get_providers](#providerget_providers)
- `host`
    - Type: string
    - Details: The name of the host to get details for. Retrieved via [provider.get_hosts](#providerget_hosts)
- Returns: table
    - A 1 dimensional table containing each hosts "details". Valid key/value pairs for details are
        - NAME (string)
        - URI (string)
        - STATE (Optional | string from [netman.options.ui.states](https://github.com/miversen33/netman.nvim/blob/main/lua/netman/tools/options.lua#L100-L104)
        - ENTRYPOINT (Optional| table of URIs, or a single function to call to get said table of URIs. Used to determine what directory to "start" the host at when displaying to the user)

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

There are additional optional functions that if implemented, will be called during the lifecycle of the provider and buffers associated with it. Those being
- [`init`](#initconfigurationoptions)
- [`close_connection`](#closeconnectionbufferindex-uri-cache)
- [`move`](#moveuris-target_uri-cache---table)
- [`copy`](#copyuris-target_uri-cache---table)
- [`archive`]()

There are 2 key variables that are provided with most calls to a [`provider`](#providers) by the [`api`](#api). Those are
- [`uri`](#uri)
- `cache`

The [`uri`](#uri) is the string representation of the remote data that the user wishes to interface with. A [`uri`](#uri) is traditionally represented in the following manner `protocol://host_authentication_information/path` and [`api`](#api) uses this assumption to determine if a [`provider`](#providers) should handle that [`uri`](#uri) or not. 

The `cache` object is a `table` that is created (as an empty table) by [`api`](#api) after calling the [`provider's`](#providers) [`init`](#initconfigurationoptions) function. This is a safe place for the [`provider`](#providers) to store `state` as it is not manipulated by anything else (including the [`api`](#api), other [`providers`](#providers), etc) and stores any changes made to it by the [`provider`](#providers). This is especially useful when establishing the initial details from the [`uri`](#uri) so the [`provider`](#providers) doesn't have to continually re-parse a [`uri`](#uri)

Details on how to implement a [`provider`](#providers) can be found within the [Developer Guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
## read(uri, cache)
- Version Added: 0.1
- Updated      : 1.01
- [`uri`](#uri)
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string [`URI`](#uri) to read
- `cache`
    - Type: [Table](https://www.lua.org/pil/2.5.html)
    - Details: The `table` object that is stored and managed by the [`api`](#api). The `api` gets this object from the [`provider`](#provider)'s [`init`](). For more details on how the cache works, consult the [Developer Guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
- Returns
  - table
    - [`read`](#readuri-cache) must return a table with the following key/value pairs
      - success: boolean
        - A true/false to indicate if the read was successful or not
      - type: string
        - A valid type as found in [`api.read`](#readuri-opts)
      - error: table (optional)
        - If there were any encountered errors, place the error here in a table where the error is attached to the `message` attribute. EG
            `error = {message = "SOMETHING CATASTROPHIC HAPPENED!"}`
      - data: table
        - A table that contains the data to consume. This data should be formed in one of the 3 following ways, depending on the `type` that is returned along side the data.
          - TYPE == 'STREAM'
            - For a `STREAM` type, simply put your data into a 1 dimensional table (where each item in the table is a "line" of output)
          - TYPE == 'EXPLORE'
            - For a `EXPLORE` type, the returned table should be a 1 dimensional table of complex tables. Each "child" table should contain the following key/value pairs
              - URI: string
                - The URI to follow to resolve this child object
              - FIELD_TYPE: string
                - The type of item being returned. See [options](#options) for valid field types
              - NAME: string
                - The name of the item to be presented to the user
              - ABSOLUTE_PATH: table
                - Another complex table that is a "path" of URIs to follow to reach this URI. An example would better demonstrate this
                    {
                        {
                            name = 'my',
                            uri = "sftp://myhost///my"
                        },
                        {
                            name = "dir",
                            uri = "sftp://myhost///my/dir"
                        }
                    }
              - METADATA: table (optional)
                - Stat compliant metadata for the item. If provided, the flags must match what are found in the [options](#options)
          - TYPE == 'FILE'
            - For a `FILE` type, the returned table must include the following 2 key/value pairs
                - local_path: string
                  - The "local" path of the item. Useful for rendering a "local" representation of the "remote" system
                - origin_path
                  - The uri that was followed for this item
        - For more information on how the [`read`](#readuri-cache) process works, please consult the [`Developer Guide`](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
- Throws: nil
- Notes
    - **IT IS NO LONGER ACCEPTABLE FOR READ TO THROW ERRORS. INSTEAD, RETURN THOSE ERRORS ALONG WITH A `success = false`**
## write(uri, cache, data, opts)
- Version Added: 0.1
- Updated      : 1.01
- `uri`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string [`URI`](#uri) to create
- `cache`
    - Type: [Table](https://www.lua.org/pil/2.5.html)
    - Details: The `table` object that is stored and managed by the [`api`](#api). The `api` gets this object from the [`provider`](#provider)'s [`init`](). For more details on how the cache works, consult the [Developer Guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
- `data`
  - Type: [Table](https://www.lua.org/pil/2.5.html)
  - Details: A table of "lines" to write to the backing store
- `opts`
  - Type: [Table](https://www.lua.org/pil/2.5.html)
  - Details: Reserved for future use
- Returns: Table
  - A table with the following key/value pairs is returned
      - uri: string (optional)
        - The URI of the written item. Useful if a new item was generated and needs to be returned, or if the provided URI is a shortcut URI (IE, not absolute)
      - success: boolean
      - error: table (optional)
        - If there were any encountered errors, place the error here in a table where the error is attached to the `message` attribute. EG
            `error = {message = "SOMETHING CATASTROPHIC HAPPENED!"}`
- Notes
    - [`api`](#api) does not currently provide any tools for dealing with oddities in the write process (permission error, network failure, etc), and those errors and validations are left up to the provider to handle.
## delete(uri, cache)
- Version Added: 0.1
- Updated      : 1.01
- `uri`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string [`URI`](#uri) to delete
- `cache`
    - Type: [Table](https://www.lua.org/pil/2.5.html)
    - Details: The `table` object that is stored and managed by the [`api`](#api). The `api` gets this object from the [`provider`](#provider)'s [`init`](). For more details on how the cache works, consult the [Developer Guide](https://github.com/miversen33/netman.nvim/wiki/Developer-Guide)
- Returns: Table
   - A table with the following key/value pairs is returned
      - success: boolean
      - error: table (optional)
        - If there were any encountered errors, place the error here in a table where the error is attached to the `message` attribute. EG
            `error = {message = "SOMETHING CATASTROPHIC HAPPENED!"}`
- Notes
    - [`api`](#api) does not currently provide any tools for dealing with oddities in the delete process (user verification, permission error, network failure, etc), and those errors and validations are left up to the provider to handle.
## move(uris, target_uri, cache)
- Version Added: 0.2
- Updated      : 1.01
- `uris`
    - Type: [Table](https://www.lua.org/pil/2.5.html)
    - Details: The table of string [`URIs`](#uri) to move
- `target_uri`
    - Type: [String](https://www.lua.org/pil/20.html)
    - Details: The string location to move the URIs to. Consider this a "parent" location to move into. Note, if a single uri is provided, it is expected that
        that the uri is "renamed" to the target_uri (as opposed to moving into that location)
- `cache`
    - Type: [Table](https://www.lua.org/pil/2.5.html)
    - Details: The provider cache as provided by the [`api`](#api)
- Returns: [Table](https://www.lua.org/pil/2.5.html)
    - Details
        - A table should be returned with the following key/value pairs (**some are optional**)
            - success: boolean
                - This should be a true or false to indicate if the move was successful or not
            - error: table (optional)
                - This should be provided in the event that you have an error to pass
                    to the caller.
                    The contents of this should be a table with a single `message` attribute (which houses a string)
                    EG: `error = { message = "SOMETHING CATASTROPHIC HAPPENED!" }`
## copy(uris, target_uri, cache)
- Version Added: 0.2
- Updated      : 1.01
- `uris`
    - Type: [Table](https://www.lua.org/pil/2.5.html)
    - Details: The table of string [`URIs`](#uri) to copy
- `target_uri`
    - Type: [String](https://www.lua.org/pil/20.html)
    - Details: The string location to copy the URIs to. Consider this a "parent" location to copy into. Note, if a single uri is provided, it is expected that
        that the uri is named to the target_uri (as opposed to copied into that location)
- `cache`
    - Type: [Table](https://www.lua.org/pil/2.5.html)
    - Details: The provider cache as provided by the [`api`](#api)
- Returns: [Table](https://www.lua.org/pil/2.5.html)
    - Details
        - A table should be returned with the following key/value pairs (**some are optional**)
            - success: boolean
                - This should be a true or false to indicate if the copy was successful or not
            - error: table (optional)
                - This should be provided in the event that you have an error to pass
                    to the caller.
                    The contents of this should be a table with a single `message` attribute (which houses a string)
                    EG: `error = { message = "SOMETHING CATASTROPHIC HAPPENED!" }`
## get_metadata(uri, requested_metadata)
- Version Added: 0.95
- `uri`
    - Type: [String](http://www.lua.org/pil/2.4.html)
    - Details: The string [`URI`](#uri) to get metadata for
- `requested_metadata`
    - Type: [Array](https://www.lua.org/pil/11.1.html)
    - Details: `requested_metadata` an array of values where each value in the array can be located in the [`Netman METADATA Table`](#options-1).
- Returns
    - Should return a [Table](https://www.lua.org/pil/2.5.html) where the `key` in each entry of the table should be from the input `requested_metadata` array
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
## close_connection(uri, cache)
- Version Added: 0.1
- Updated      : 1.01
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
- api
    - READ_TYPE
        - FILE
        - STREAM
        - EXPLORE
    - ATTRIBUTES
        - FILE
        - DIRECTORY
        - LINK
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

