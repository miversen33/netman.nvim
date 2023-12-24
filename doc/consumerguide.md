<sup>[Source can be found here](https://github.com/miversen33/netman.nvim/blob/main/doc/consumerguide.md)</sup>  

# Overview

If you're trying to figure out how to use netman for your own plugin, this is the guide for you! The goal of this document is to walk you through the following points

- [How to request information from a URI](#requesting-information-from-a-uri)
  - [TLDR](#short-example)
  - [In Depth Details](#long-example)
- [How to update the data behind that URI](#updatingdeleting-data-for-a-uri)
  - [TLDR](#short-update-example)
  - [In Depth Details](#long-update-example)
- [How to delete the data behind that URI](#updatingdeleting-data-for-a-uri)
  - [TLDR](#short-update-example)
  - [In Depth Details](#long-update-example)
- [How to move/copy your URI to a different URI](#async-copymove)
  - [TLDR](#short-copy-example)
- [How to get the metadata for that URI](#requesting-metadata-for-uri)
  - [TLDR](#short-get-metadata-example)
- How to modify the metadata for that URI - Coming Soon
- [How to get the available providers within Netman](#getting-list-of-available-providers)
- [How to get the hosts available on each provider within Netman](#getting-list-of-available-providers)

# Requesting Information from a URI

One of the most important things a consumer will want to do is "read" from a URI. That is, to get the contents of whatever is behind the URI. As an example, a user may want to open `ssh://a-really-cool-host///etc/nginx/nginx.conf`. A consumer's job then is to tell Netman to open this URI and render out the contents of it to the User. This is done via the `api.read` function within Netman's [api](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#readuri-opts)

## Short Example

Below is a small snippet to show you how to **synchronously** read this URI

```lua
-- Defining a couple module imports
local inspect = vim and vim.inspect or require("inspect")
local netman_api = require("netman.api")
-- Pretty Printing the output of netman_api.read
print(inspect(netman_api.read("ssh://a-really-cool-host///etc/nginx/nginx.conf")))
```

<!-- Tag Stream or File -->
In this case, we (as the reader) can safely assume that the output of this URI is likely to be either a `STREAM` or a `FILE`. These terms are documented more [in the api.read technical document](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#readuri-opts). This means we _should_ see output matching in the following format

```lua
{
    success = true,
    type = 'FILE',
    data = {
        local_path = "$SOME_PATH_ON_YOUR_LOCAL_MACHINE$",
        origin_path = "/etc/nginx/nginx.conf"
    }
}
```

Awesome! What does this mean though? Below is a break down of what each item in the above return value means and how we should process it.

## Short Return Explanation

- success = true
  - The read was completed successfully
- type = 'FILE'
  - This indicates that the return information (found in the `data` attribute) is a Netman File type. More details on the various return types can be found [in the netman api.read technical document](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#readuri-opts).
- data = `table`
  - A table containing the relevant data to be used to render the result for the user. This is the important bit for us as a consumer!  Here the data table tells us that the file can be found at `$SOME_PATH_ON_YOUR_LOCAL_MACHINE$`. We should open that file, and then rename it to the URI that we told Netman to read (so its consistent with what the user would expect).

Congratulations! We have successfully read information from Netman's api using the core [`ssh`](https://github.com/miversen33/netman.nvim/blob/main/lua/netman/providers/ssh.lua) provider. Let's talk about that `synchronous` bit from earlier.

## Async Reading

As mentioned, the above read will run synchronously. This can be painful if the data being read is large, the connection is poor, or we are impatient. How then do we run reads (and other functions) asynchronously?

The `tldr` is, simply provide a callback to `api.read` as its final parameter. This changes the above call from

```lua
api.read("ssh://a-really-cool-host///etc/nginx/nginx.conf")
```

to

```lua
api.read(
    "ssh://a-really-cool-host///etc/nginx/nginx.conf",
    {},
    function(data) print(inspect(data)) end
)
```

This will mutate the return structure to a valid Async handle, as laid out in [API Async Return](#api-async-return)

## Long Example

[The above](#short-example) is a "short and sweet" explanation of how to quickly read the resources behind a URI in netman. Below will be more details on how this read command works, the steps the API walks through, and any events fired during the read process.

### Validate the URI

The first step in the api `read` process is validation of the provided URI. This step involves

- Extracting the `protocol` from the URI
- Fetching a matching `provider` for the protocol
- Fetching the `cache` object for the `provider`

If no `provider` is found to match the protocol, the api will fail and the following will be returned (regardless of if the process is sync or async)

```lua
{
  success = false,
  message = {
    message = "Unable to read $URI$ or unable to find provider for it"
  }
}
```

This is considered a "validation" error and will occur before any sort of processing happens. Validation errors will always return immediately, as the api (at this point) has no idea if the process is async or not. Its effectively the same as throwing an error and dying, however the api tries its absolute best to **not** explode. This is the result of that trying.

**NOTE: Always be sure to check the `success` response from the API, and if there is a message its best to at least log it somewhere. Depending on circumstance, you way wish to pass that up to the user. For more details on api messages, check out [`how providers communicate with you`]()**

### Synchronous Example

```lua
local inspect = vim and vim.inspect or require("inspect")
local netman_api = require("netman.api")
local uri = "ssh://a-really-cool-host///etc/nginx/nginx.conf"

print(inspect(netman_api.read(uri)))

```

```lua
-- Printed Response
{
    success = true,
    type = 'FILE',
    data = {
        local_path = "$SOME_PATH_ON_YOUR_LOCAL_MACHINE$",
        origin_path = "/etc/nginx/nginx.conf"
    }
}
```

To break this down, the `api.read` function performs the following actions.

#### Sync Check existing connection to host

Next a quick check with the provider is performed, where the provider will indicate if it has a pre-existing connection to the host of the URI. **This should be quite quick as it is a simple `T/F`, and done here simply because the logic splits below both need this information.**

#### Check if async is possible (perform `ASP` check)

The API will now check to see if async is possible for the request. We did not provide a callback, so the `ASP` check is immediately invalidated and a `synchronous` read request is began.

#### Synchronous Cache Check

After validation has completed, the API will check the `file cache` it keeps for each provider. If there is a file path stored for the requested `URI`, (and the user did _not_ provide option `force=true`), the API will return a "properly formatted response" with that cache location. Note, to bypass this, you can provide an optional second parameter which is a table, with `force=true`.

```lua
local inspect = vim and vim.inspect or require("inspect")
local netman_api = require("netman.api")
local uri = "ssh://a-really-cool-host///etc/nginx/nginx.conf"

print(inspect(netman_api.read(uri, { force = true })))
```

The purpose of this cache is to prevent consumers from running multiple "reads" on the same URI in quick succession. This cache is _very_ short lived (the TTL is 1 minute). A provider may also cache these items and they may live much longer there as that is _outside_ the control of the API. The above `force` flag _is provided_ to the provider on read, and it is expected that a provider respects this. However we **cannot** enforce it as we do not know if the provider returns a cached response or not. **Ye be warned.**

#### Sync Verify connection to host

The API previously [checked with the provider to see if it had a connection to the host of the URI](#sync-check-existing-connection-to-host). If the provider indicated it did not, the API will now reach out to the provider to synchronously establish that connection.

#### Execute synchronous read

After all the checks are completed, the API will reach out to the provider to execute a synchronous read request.

#### Sync Validate Read Data

The provider has now returned whatever information was relevant to the `read` request we executed. The API now validates the data returned to ensure it matches the expected output of a provider on `read`. This step is where errors may be generated (and `success` may be set to `false`), depending on if the provider returns invalid data.

Things being validated here are

- Did the provider return data at all?
- Did the provider indicate a failure of some kind during the read?
- Did the provider return a valid data `TYPE`? Valid data types are `STREAM`, `FILE`, and `EXPLORE`.
- If the data is a `FILE` type, did the provider return a correctly formatted table?
- If the data is an `EXPLORE` type, did the provider return a correctly formatted table?

#### Sync Return the Read Data

Once the synchronous read has been completed and validated, the API returns the data to the caller.

**NOTE: If the read data is of type `FILE`, we will cache the file location temporarily to quickly feed that back on subsequent read requests. See [check cache](#sync-check-existing-connection-to-host) for details on this**

### Asynchronous Example

This will walk through a more in depth explanation of how async reads work within the API. It is assumed that you have read [async reading](#async-reading) already.

Below is some example code for reading the same file asynchronously

```lua
local inspect = vim and vim.inspect or require("inspect")
local netman_api = require("netman.api")
local uri = "ssh://a-really-cool-host///etc/nginx/nginx.conf"

local function read_processor(data)
  print("Async Response: ", inspect(data))
end

print("Initial Response:", inspect(netman_api.read(uri, {}, read_processor)))

-- First Printed Response, off the read result itself
-- Initial Response: {
--    success = true,
--    handle = {
--        read  = <function>,
--        write = <function>,
--        stop  = <function>,
--    }
-- }
--
-- Second Printed Response, off the results of the read
--  Async Response: {
--    success = true,
--    type = 'FILE',
--    data = {
--        local_path = "$SOME_PATH_ON_YOUR_LOCAL_MACHINE$",
--        origin_path = "/etc/nginx/nginx.conf"
--    }
-- }
```

If you read [the synchronous example](#synchronous-example), you will notice that the information that was previously returned after `read` successfully completed, is now being passed to the callback. We are now getting something completely different in the initial return of `read`.

Because we asked `read` to execute asynchronously, we are instead returned a handle to interact with the asynchronous process. That handle exposes the following 3 functions

- `read`
- `write`
- `stop`

For details on this return structure, see the [API Async Return](#api-async-return).

To break this down, the `api.read` function performs the following actions.

#### Validate the URI 2

See [Validate the URI](#validate-the-uri) as this is literally the same thing.

#### Async Check existing connection to host

Next a quick check with the provider is performed, where the provider will indicate if it has a pre-existing connection to the host of the URI. **This should be quite quick as it is a simple `T/F`, and done here simply because the logic splits after this, its easier for the API to determine this once and pass it along to the async or sync read functions.**

#### Asynchronous Check Cache

After validation has completed, the API will check the `file cache` it keeps for each provider. If there is a file path stored for the requested `URI`, (and the user did _not_ provide option `force=true`), the API will stream a "properly formatted response" with that cache location. Note, to bypass this, you can provide an optional second parameter which is a table, with `force=true`.

```lua
local inspect = vim and vim.inspect or require("inspect")
local netman_api = require("netman.api")
local uri = "ssh://a-really-cool-host///etc/nginx/nginx.conf"
local function read_processor(data)
  print(inspect(data))
end

print(inspect(netman_api.read(uri, { force = true }, read_processor)))
```

The purpose of this cache is to prevent consumers from running multiple "reads" on the same URI in quick succession. This cache is _very_ short lived (the TTL is 1 minute). A provider may also cache these items and they may live much longer there as that is _outside_ the control of the API. The above `force` flag _is provided_ to the provider on read, and it is expected that a provider respects this. However we **cannot** enforce it as we do not know if the provider returns a cached response or not. **Ye be warned.**

#### Async Verify connection to host

The API previously [checked with the provider to see if it had a connection to the host of the URI](#async-check-existing-connection-to-host). If the provider indicated it did not, the API will check to see if the provider has implemented an asynchronous `connect` function. This function is **not required** per the provider spec and thus may not be available on all providers. This is ok, but it does mean that its possible reads might take a bit longer as the API cannot preconnect the provider and host of the URI.

**NOTE: A provider's failure to implement the asynchronous `connect` function does not result in a failed `ASP` check.**

#### Check if async is possible (perform `ASP` check)

The API will now check to see if async is possible for the request. As we provided a callback, the first step in [`ASP`](#async-reading) (**ask**) is fulfilled.

The second step is for the API to verify that the provider _can_ perform the read asynchronously. The API will check that the provider has implemented the appropriate asynchronous read function(s). If they are available, the second step (**say**) has been fulfilled. If not, we will proceed with a synchronous read and just forward the return information to the provided callback, "emulating" an async call with sync data.

If the second step is validated, the API will run the read asynchronously. If the provider fails to return a valid async handle, the API will remove the async function from the provider, thus failing the final step in `ASP` (**prove**). It will also fall back to the aforementioned "faux async" handling for of sync data.

If an `ASP` failure is encountered **after the `ask` validation has completed**, the process will revert back to synchronously fetching the requested data and providing said data in the expected asynchronous manner. IE, the data will be provided to the callback and a handle will still be returned by the API.

#### Execute asynchronous read

After Check 1 and Check 2 (Ask and Say) are completed, the API will reach out to the provider to execute an asynchronous read request. It will then immediately validate that it receives an appropriate async handle.

If the api does _not_ receive the expected handle, it will still let the provider finish, but it will rip out the asynchronous read function to prevent further bad behavior of the provider. Errors may likely be logged during this.

#### Async Validate Read Data

The API provides its _own_ callback to a provider for the asynchronous read event. **Note, this means that you will _not_ receive the raw information from the provider**. As the provider streams information to the callback, the API will sanitize it and ensure it is valid. If it is _not_ valid, the data is logged out and discarded to ensure a consistent read experience between the consumer and provider. This validation is exactly the same as [the synchronous data validation](#sync-validate-read-data), so it is assumed you read that.

As the data is validated and sanitized, it is passed to the callback that we provided it. This will come in the form of the following table

```lua
{
  type = "FILE", -- or "STREAM", or "EXPLORE"
  data = {} -- Whatever was provided by the provider post sanitization
}
```

It should be noted that return type `EXPLORE` data will actively be streamed back to the callback as its received. This means you may receive several calls to your callback with bits of data before you receive a `{success = true}` argument.

It should additionally be noted that return type `STREAM` means that everything in the `data` table is what was streamed directly from the provider.

**`STREAM` != `EXPLORE` in this context and should not be confused.**

Eventually when the provider indicates it is done with the read, the callback will be called with the following argument

```lua
{
  success = true
}
```

This indicates that the read has finished **and** finished successfully. At any point during asynchronous read, the provider (or api) may return

```lua
{
  success = false
}
```

Which would _also_ indicate that the read has finished, except it was **not** successful this time. In a situation where `success = false`, there is **usually** _(but not guaranteed)_ an additional `message` attribute in the table. This attribute will be structured as follows

```lua
message = {
  message = "SOME MESSAGE",
  default = "" -- This may be provided if the provider has a default value they want you to use for their input
  retry = false -- or true, or a function to call
}
```

If `retry` is indicated, it will be either `true`, `false`, or a `function`.

`True` is meant to indicate that the provider ran into some issue that it was able to resolve but still broke the existing call. This is rare but may happen.

`False` (or nil) means that there is no need to retry, an error occurred and its up to the consumer to bubble that error up to the user.

`function` (a callable) means that the provider needs some information from the user. In this case, `message` should be displayed in an input and whatever string the user replies with should be fed directly into the function. This is a means for the provider to allow the consumer to shape the callbacks within the consumer's UI/UX while still allowing the provider to get whatever information it needs. This will likely be used for "confirmations" and "password" retrieval as an example.

`default` may be provided and will always be a string if it is. This variable is meant to be used as the "default value" in an input that you the consumer are to render to the user

#### Return the Read Data

As this is running asynchronously, there is nothing for us to return data wise. The return of `api.read` in this case is the [aforementioned handle](#asynchronous-example).

# Updating/Deleting Data for a URI

Another very important thing a consumer will want to do is "update" a URI. That is, to update the contents of whatever is behind the URI. As an example, a user may want to add some new lines to a configuration located at `ssh://a-really-cool-host///etc/nginx/nginx.conf`. A consumer's job then is to tell Netman that you want to save new information in place of whatever is currently stored at that endpoint. This is done via the `api.write`, and `api.delete` functions within Netman's [api](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#api)

## Short Update Example

Below is a small snippet to show you how to **synchronously** write to this URI

```lua
-- Defining a couple module imports
local inspect = vim and vim.inspect and require("inspect")
local netman_api = require("netman.api")
print(inspect(netman_api.write('ssh://a-really-cool-host///etc/nginx/nginx.conf', {"new lines to overwrite config with"})))
```

```lua
-- Printed Return Data
{
  success = true
}
```

## Short Update Return Explanation

- success = true
  - The write was completed successfully

Congratulations! We have successfully updated the above nginx config using Netman's api and the core `ssh` provider. Remember, this is a synchronous write! So Neovim will lock up while the writing to the URI. This may be fine for small writes over a fast network, but typically you will find that you want this be ran in the background.

## Async Updating

Just like with [async reading](#async-reading), you can easily specify you want the provider to run its update (`write`/`delete`) asynchronously by simply adding a callback as an additional parameter. This changes the above call from

```lua
api.write('ssh://a-really-cool-host///etc/nginx/nginx.conf', {"new lines to overwrite config with"})
```

to

```lua
api.write(
  'ssh://a-really-cool-host///etc/nginx/nginx.conf', 
  {"new lines to overwrite config with"},
  {},
  function(data)
    print(inspect(data))
  end
)
```

The `ASP` model is detailed more in [`API ASP Validation`](#api-asp-validation) and thus we won't go into it in depth here. Just remember, any asynchronous functionality in Netman's API will follow the `ASP` model. This includes `api.write` and `api.delete`.

## Long Update Example

[The above](#short-update-example) is a "short and sweet" explanation of how to quickly write to the resource behind a URI in Netman. Below will be more details on how this write command works, the steps the API walks through, and any events fired during the write process. The same general principals can be applied to `api.delete` and thus we will only be covering `write` here.

### Synchronous Update Example

```lua
local inspect = vim and vim.inspect or require("inspect")
local netman_api = require("netman.api")
local uri = "ssh://a-really-cool-host///etc/nginx/nginx.conf"

print(inspect(netman_api.write('ssh://a-really-cool-host///etc/nginx/nginx.conf', {"new lines to overwrite config with"})))
```

```lua
-- Printed Return Data
{
    success = true,
}
```

To break this down, the `api.write`/`api.delete` function performs the following actions

- [API Request Validation](#api-request-validation)
- Call the provider's respective function (`write`/`delete`)
- Return either a success table or async handle to the consumer, depending on the aforementioned `ASP validation` results.[How to get the metadata for that URI]


# Copying/Moving a URI to another URI

Among the things that a user might wish to do, being able to "move" or "copy" a URI to another URI is certainly higher up on the list. As such, Netman provides an abstracted way to perform this action both synchronously and asynchronously. Before getting too deep into the weeds here, it should be called out
**Copy and Move are _not_ required functions for a provider to implement and thus your attempts to perform these may not work. If the provider did not implement the necessary functions to perform a copy/move, you will get a failure returned to you!**

## Short Copy Example

`Copy` and `Move` both have the exact same signature and return details and thus only `copy` will be detailed here.
Below is a small snippet to show you how to synchronously `copy` a URI to another URI.

```lua
-- Defining a couple module imports
local inspect = vim and vim.inspect and require("inspect")
local netman_api = require("netman.api")
print(inspect(netman_api.copy('ssh://a-really-cool-host///etc/nginx/nginx.conf', 'ssh://a-really-cool-host///etc/nginx/nginx.conf')))
```

```lua
-- Printed Return Data
{
  success = true
}
```

## Short Copy Return Explanation

- success = true
  - The write was completed successfully

Congratulations! We have successfully copied a URI to a second location using Netman's api and the core `ssh` provider. Remember, this is a synchronous write! So Neovim will lock up while the writing to the URI. This may be fine for small writes over a fast network, but typically you will find that you want this be ran in the background.

## Async Copy/Move

Just like [async reading](#async-reading), you can easily specify you want the provider to run its copy/move asynchronously by simply adding a callback as an additional parameter. This changes the above call from

```lua
api.copy('ssh://a-really-cool-host///etc/nginx/nginx.conf', 'ssh://a-really-cool-host///etc/nginx/nginx.conf')
```

to

```lua
api.copy(
  'ssh://a-really-cool-host///etc/nginx/nginx.conf',
  'ssh://a-really-cool-host///etc/nginx/nginx.conf',
  {},
  function(data) print(inspect(data)) end
)
```

The `ASP` model is detailed more in [`API ASP Validation`](#api-asp-validation) and thus we won't go into it in depth here. Just remember, any asynchronous functionality in Netman's API will follow the `ASP` model. This includes `api.copy` and `api.move`.

<!-- ## Long Copy/Move Example -->

## API Async Return

When calling a function asynchronously in Netman, Netman's API will actually mutate the return signature of said function. A function that is called asynchronously within Netman will always return with the same structure, regardless of what its _synchronous_ counterpart would return.

```lua
-- Printed Return Data
{
  read = function(pipe: string) -> table,
  write = function(data: table|string) -> nil,
  stop = function(force: boolean) -> nil
}
```

This structure will allow a consumer to interact with the underlying asynchronous process/processes without having to establish _which_ current process you need to deal with. All these functions are safe to call at any time in the life of the request.

A note, a consumer _likely_ won't need to use `read` often as most of the time their callback should be passed any data they need to read. However, `read` _can_ be used to potentially view the underlying STDOUT/STDERR pipe if a developer is trying to troubleshoot something within their request process.

# Requesting Metadata for URI

As a consumer of the data provided by Netman, you may very well care about the "metadata" for a URI. That is, you might care about the data related to the data. Is the URI a "directory"? How big is it? When was it last modified? Etc, this is all "metadata". And the Netman API provides a way to request this metadata.

## Short Get Metadata Example

### Sync Get Metadata Example

```lua
-- Defining a couple module imports
local inspect = vim and vim.inspect and require("inspect")
local netman_api = require("netman.api")
print(inspect(netman_api.get_metadata('ssh://a-really-cool-host///etc/nginx/nginx.conf')))
```

```lua
-- Printed Return Data
{
  data = {
    ABSOLUTE_PATH = { {
        name = "etc",
        uri = "ssh://a-really-cool-host///etc/"
      }, {
        name = "nginx",
        uri = "ssh://a-really-cool-host///etc/nginx/"
      }, {
        name = "nginx.conf",
        uri = "ssh://a-really-cool-host///etc/nginx/nginx.conf"
      } },
    BLKSIZE = "512",
    FIELD_TYPE = "DESTINATION",
    GROUP = "root",
    INODE = "533487",
    MTIME_SEC = "1687533200",
    NAME = "nginx.conf",
    PERMISSIONS = "644",
    SIZE = "596",
    TYPE = "regular file",
    URI = "ssh://a-really-cool-host///etc/nginx/nginx.conf",
    USER = "root"
  },
  success = true
}
```

### Short Get Metadata Return Explanation


So what does all this mean?

- success = true
  - Indicates that the request was successful. Always check this before checking data
- `data`
  - This is the key that will contain the relevant "metadata" on to inspect
    - The keys in `data` are closely related to the various `STAT` flags you can request with the linux `STAT` command. Thus there won't be a great deal of effort put into explaining most of them. There are a few keys that deserve to be called out though
      - URI
        - The absolute URI to follow to interact with this resource.
      - FIELD_TYPE
        - This will be either `DESTINATION` or `LINK` and is used to indicate if the resource is an endpoint (think like a file) or it contains more resources (think directory). The distinction is made here specifically to handle the fact that Netman generally doesn't know what a "file" or "directory" is, and keeping distinctly different from `file`, and `directory` will make it easier for netman to support "non" filesystems (such as databases).
      - ABSOLUTE_PATH
        - An array of URIs to follow to "navigate to" this location. This is very useful if you wish to display a sort of "path" leading to the resource. Think along the lines of "tree" displays.

### Async Get Metadata Example

```lua
-- Defining a couple module imports
local inspect = vim and vim.inspect and require("inspect")
local netman_api = require("netman.api")
print(inspect(netman_api.get_metadata('ssh://a-really-cool-host///etc/nginx/nginx.conf', nil, nil, function(data) print(data) end)))
```

```lua
-- Printed Return Data
{
  read = function(pipe: string) -> table,
  write = function(data: table|string) -> nil,
  stop = function(force: boolean) -> nil
}
```

Async `get_metadata` will mutate the return structure to a valid Async handle, as laid out in [API Async Return](#api-async-return)

## Long Get Metadata Example

# API Request Validation

When a request is made to the API, it will perform the following steps to ensure the request is able to be processed.

## Get the provider and cache for the URI

The API will parse the URI and establish which provider (and associated cache) the URI belongs to. The parsing is done by a simple lua glob that pulls any word characters from the front of the URI until `://` is found. This glob `'^([%w%-.]+)://'` is what is used to determine the protocol of a provider. Once the protocol is found, the API will try to find a match with any of the registered providers.

If a match cannot be found then you can expect a failure response on _any_ API command provided.

## API ASP Validation

After the provider has been established, the `ASP` validation is performed. `ASP` is short for `Ask, Say, Prove` and is the methodology that is followed by the API to ensure as safe an experience with provider asynchronous communication as possible. The following are the `ASP` steps broken out.

  First, The API will check to see if the call is being requested as **asynchronous**. This is the `Ask` step in ASP.
    A consumer must provider a callback parameter to the respective api function.
  Next the provider needs to say it can perform the action asynchronously.
    The provider must announce it supports the requested asynchronous function. **This is not something the consumer needs to be concerned about and is strictly listed here for clarity into the Async validation process within Netman's API**
  The provider needs to prove it perform the requested asynchronous action.
    The provider must return a valid asynchronous handle. Again, not something the consumer needs to worry about, but a provider failing to do this will render it unable to be used asynchronously by the API.

This ask, say, prove (ASP) model is used to ensure as consistent an experience with asynchronous interaction as possible. If the consumer fails to ask for something to be ran asynchronously, it will not run asynchronously. If the provider fails to say it can run asynchronously, it will not run asynchronously. And finally, if the provider said it could but failed to prove it, then the api will remove its asynchronous capabilities for that function, preventing future bad behavior.

Running requests asynchronously can be quite beneficial (and generally gives a performance increase on more painful operations within a provider). The biggest thing to remember is that even if you ask for the api to run something asynchronously, it may not be able to complete that for one reason or another. The data will still follow the async flow however. So you will still get a handle back, though the handle will not be interactable (as the handles under it will be completed and removed by the time you get it). Your data will be provided through the provided callback synchronously as opposed to asynchronously (in the event that we cannot run asynchronously). Etc.

# Getting list of available providers

There may be times when you wish to display the providers that are available in netman. The best way to retrieve this via the `netman.ui` module. Specifically the `ui.get_providers` function. An example

```lua
local inspect = vim and vim.inspect and require("inspect")
local netman_ui = require("netman.ui")
print(inspect(netman_ui.get_providers()))
```

```lua
-- Printed results
{
  docker = {
    hosts = <function 1>,
    path = "netman.providers.docker",
    ui = {
      highlight = "",
      icon = ""
    }
  },
  ssh = {
    hosts = <function 2>,
    path = "netman.providers.ssh",
    ui = {
      highlight = "",
      icon = ""
    }
  }
}
```

More details on this can be found with `:h netman.ui.get_provider`, however the main things to care about here are

1) The key to each provider is its "display" name
2) `hosts` is a function that is designed to be lazy called to fetch the available hosts only when you are ready for them. This is because it may be "expensive" for a provider to fetch the available hosts

