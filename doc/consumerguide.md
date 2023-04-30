<sup>[Source can be found here](https://github.com/miversen33/netman.nvim/blob/main/doc/consumerguide.md)</sup>  

# Overview

If you're trying to figure out how to use netman for your own plugin, this is the guide for you! The goal of this document is to walk you through the following points

- [How to request information from a URI](#requesting-information-from-a-uri)
- [How to update the data behind that URI]
- [How to delete a URI]
- [How to move/copy your URI to a different URI]
- [How to get the metadata for that URI]
- How to modify the metadata for that URI - Coming Soon
- [How to get the available providers within Netman]
- [How to get the hosts available on each provider within Netman]
- [Async In Depth]

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
    nil,
    function(data) print(inspect(data)) end
)
```

Asynchronous anything can be fickle and asynchronous reads in netman are unfortunately no exception. In order for a read ([or any supported function]()) to be asynchronous, the following criteria needs to be met.

- We need to **ask** for it.
  - We must provider a callback parameter to the `api.read` function. In the above example, we do that and thus this criteria is met.
- The provider needs to **say** it can.
  - The provider must announce it supports asynchronous reads. This is something that the API handles validating, it is not something the consumer (we) need to worry about.
- The provider needs to **prove** it can.
  - The provider must return a valid asynchronous handle. Again, not something we need to worry about, but a provider failing to do this will render it unable to be used asynchronously by the API.

This `ask, say, prove` (`ASP`) model is used to ensure as consistent an experience with asynchronous interaction as possible. If we fail to **ask** for something to be ran asynchronously, it will not run asynchronously. If the provider fails to **say** it can run asynchronously, it will not run asynchronously. And finally, if the provider said it could but failed to **prove** it, then the api will remove its asynchronous capabilities for that function, preventing future bad behavior.

<!-- TODO: Implement this???? -->
Running `read` asynchronously can be quite beneficial (and generally gives a performance increase on more painful operations within a provider). The biggest thing to remember is that even if you **ask** for the api to run something asynchronously, it may not be able to complete that for one reason or another. _The data will still follow the async flow_ however. So you will still get a handle back, though the handle will not be interactable (as the handles under it will be completed and removed by the time you get it). Your data will be provided through the provided callback synchronously as opposed to asynchronously (in the event that we cannot run asynchronously). Etc.

With all of that out of the way, if you want more details on how async works, check out the [`Asynchronous Example`](#asynchronous-example) section below.

## Long Example

[The above](#short-example) is a "short and sweet" explanation of how to quickly read the resources behind a URI in netman. Below will be more details on how this read command works, the steps the API walks through, and any events fired during the read process.

### Synchronous Example

```lua
local inspect = vim and vim.inspect or require("inspect")
local netman_api = require("netman.api")
local uri = "ssh://a-really-cool-host///etc/nginx/nginx.conf"

print(inspect(netman.api.read(uri)))

-- Printed Response
--  {
--    success = true,
--    type = 'FILE',
--    data = {
--        local_path = "$SOME_PATH_ON_YOUR_LOCAL_MACHINE$",
--        origin_path = "/etc/nginx/nginx.conf"
--    }
-- }
```

To break this down, the `api.read` function performs the following actions.

#### Validate the URI

The api will perform a validation on the URI. This step involves  

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

#### Sync Check existing connection to host

Next a quick check with the provider is performed, where the provider will indicate if it has a pre-existing connection to the host of the URI. This should be quite quick as it is a simple `T/F`, and done here simply because the logic splits below both need this information.

#### Check if async is possible (perform `ASP` check)

The API will now check to see if async is possible for the request. We did not provide a callback, so the `ASP` check is immediately invalidated and a `synchronous` read request is began.

#### Synchronous Cache Check

After validation has completed, the API will check the `file cache` it keeps for each provider. If there is a file path stored for the requested `URI`, (and the user did _not_ provide option `force=true`), the API will return a "properly formatted response" with that cache location. Note, to bypass this, you can provide an optional second parameter which is a table, with `force=true`.

```lua
local inspect = vim and vim.inspect or require("inspect")
local netman_api = require("netman.api")
local uri = "ssh://a-really-cool-host///etc/nginx/nginx.conf"

print(inspect(netman.api.read(uri, { force = true })))
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
  print(inspect(data))
end

print(inspect(netman.api.read(uri, nil, read_processor)))

-- First Printed Response, off the read result itself
--  {
--    success = true,
--    handle = {
--        read  = <function>,
--        write = <function>,
--        stop  = <function>,
--    }
-- }
--
-- Second Printed Response, off the results of the read
--  {
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

We don't care about the first 2 as in this case we planning on processing the data as it is passed to the callback, and we have nothing useful to "write" to the asynchronous process. The last function, `stop`, may actually be useful to you however. This handle is detailed more in [`async-in-depth`](), but as an aside, `stop` can be used to "stop" the asynchronous process. This is useful if `read` is taking too long or the user has indicated they want to do something else instead.

To break this down, the `api.read` function performs the following actions.

#### Validate the URI 2

See [Validate the URI](#validate-the-uri) as this is literally the same thing.

#### Async Check existing connection to host

Next a quick check with the provider is performed, where the provider will indicate if it has a pre-existing connection to the host of the URI. This should be quite quick as it is a simple `T/F`, and done here simply because the logic splits after this, its easier for the API to determine this once and pass it along to the async or sync read functions.

#### Asynchronous Check Cache

After validation has completed, the API will check the `file cache` it keeps for each provider. If there is a file path stored for the requested `URI`, (and the user did _not_ provide option `force=true`), the API will stream a "properly formatted response" with that cache location. Note, to bypass this, you can provide an optional second parameter which is a table, with `force=true`.

```lua
local inspect = vim and vim.inspect or require("inspect")
local netman_api = require("netman.api")
local uri = "ssh://a-really-cool-host///etc/nginx/nginx.conf"
local function read_processor(data)
  print(inspect(data))
end

print(inspect(netman.api.read(uri, { force = true }, read_processor)))
```

The purpose of this cache is to prevent consumers from running multiple "reads" on the same URI in quick succession. This cache is _very_ short lived (the TTL is 1 minute). A provider may also cache these items and they may live much longer there as that is _outside_ the control of the API. The above `force` flag _is provided_ to the provider on read, and it is expected that a provider respects this. However we **cannot** enforce it as we do not know if the provider returns a cached response or not. **Ye be warned.**

#### Async Verify connection to host

The API previously [checked with the provider to see if it had a connection to the host of the URI](#async-check-existing-connection-to-host). If the provider indicated it did not, the API will check to see if the provider has implemented an asynchronous `connect` function. This function is **not required** per the provider spec and thus may not be available on all providers. This is ok, but it does mean that its possible reads might take a bit longer as the API cannot preconnect the provider and host of the URI.

NOTE: A provider's failure to implement the asynchronous `connect` function **does not** result in a failed `ASP` check.

#### Check if async is possible (perform `ASP` check)

The API will now check to see if async is possible for the request. As we provided a callback, the first step in [`ASP`](#async-reading) (**ask**) is fulfilled.

The second step is for the API to verify that the provider _can_ perform the read asynchronously. The API will check that the provider has implemented the appropriate asynchronous read function(s). If they are available, the second step (**say**) has been fulfilled. If not, we will proceed with a synchronous read and just forward the return information to the provided callback, "simulating" an async call with sync data.

If the second step is validated, the API will run the read asynchronously. If the provider fails to return a valid async handle, the API will remove the async function from the provider, thus failing the final step in `ASP` (**prove**). It will also fall back to the aforementioned "faux async" handling for of sync data.

If an `ASP` failure is encountered **after the `ask` validation has completed**, the process will revert back to synchronously fetching the requested data and providing said data in the expected asynchronous manner. IE, the data will be provided to the callback and a handle will still be returned by the API.

#### Execute asynchronous read

After all the checks are completed, the API will reach out to the provider to execute an asynchronous read request. It will then immediately validate that it receives an appropriate async handle.

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

`STREAM` != `EXPLORE` in this context and should not be confused.

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
  retry = false -- or true, or a function to call
}
```

If `retry` is indicated, it will be either `true`, `false`, or a `function`.

`True` is meant to indicate that the provider ran into some issue that it was able to resolve but still broke the existing call. This is rare but may happen.

`False` (or nil) means that there is no need to retry, an error occurred and its up to the consumer to bubble that error up to the user.

`function` (a callable) means that the provider needs some information from the user. In this case, `message` should be displayed in an input and whatever string the user replies with should be fed directly into the function. This is a means for the provider to allow the consumer to shape the callbacks within the consumer's UI/UX while still allowing the provider to get whatever information it needs. This will likely be used for "confirmations" and "password" retrieval.

#### Return the Read Data

As this is running asynchronously, there is nothing for us to return data wise. The return of `api.read` in this case is the [aforementioned handle](#asynchronous-example).
