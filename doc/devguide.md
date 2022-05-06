# Welcome to the Netman Developer Guide!
Here you will find a breakdown of the following items
- [TLDR](#tldr)
- [The Netman Buffer Object Life Cycle](#the-netman-buffer-object-life-cycle)
    - [How the heck does the api work?](#how-the-heck-does-the-api-work)
    - [What _is_ a provider?](#what-is-a-provider)
- [How to create a provider!](#how-to-create-a-provider)
    - [Initial Considerations](#initial-considerations)
    - [Integration with api](#integration-with-api)
    - [Help my provider is broke!](#how-to-troubleshoot-your-shiny-new-provider)

## TLDR

## The Netman Buffer Object Life Cycle
The "Netman Buffer Object" is the object that `api` creates to help keep track of data associated with a `neovim` buffer. This is automatically created by the `api` when `neovim` creates a buffer (via the [`FileReadCmd`](https://neovim.io/doc/user/autocmd.html#FileReadCmd), or [`BufReadCmd`](https://neovim.io/doc/user/autocmd.html#BufRead)). This object is **only** created for buffers where the file `uri` being opened is associated with a provider.

> But how does `api` associate a `uri` with a provider?

Netman is a clever little program, it only pays attention to buffer open events based on the `file name` (as `neovim` considers it). Netman selectively creates [`event listeners`](https://neovim.io/doc/user/autocmd.html#events) specifically for protocols as registered by providers. This means that if you have a provider loaded for `ssh` <details><summary>spoiler alert</summary> [you do if you are using `Netman`](https://github.com/miversen33/netman.nvim/blob/main/lua/netman/providers/ssh.lua)</details> and no other providers, `Netman` will only listen to files opened that start with `ssh` related protocols (as defined by the `ssh` provider). There is no limit to the number of providers that Netman can have loaded at one time, Netman will only listen for events related to the protocols that the loaded providers specify they can handle. These events listeners (called `autocommands` in `vim` speak) are all cleanly housed in the `Netman` command group (called `augroup` in `vim` speak).

Netman will use this object to track internal metadata about the `uri` (its `provider`, if it has a local file stored somewhere, what buffer its on, a `provider cache`, etc). This is to help prevent Netman from having to redo logic when seeing a `uri` that is has already processed. Additionally, this buffer object contains a `provider` specific cache that is passed to the provider on most function calls so the provider can safely store "relevant" information to the uri.

> Ok thats cool but what about when the user is done with the file?

Netman has its greedy little hooks into a handful of places in `neovim`'s event system, one of those places being the [`BufUnload`](https://neovim.io/doc/user/autocmd.html#BufUnload) event. When `neovim` fires this event on a buffer that Netman is watching, Netman will receive the event and proceed to clear out the object from its memory. Additionally, if the `provider` associated with the buffer has implemented the `close_connection` function, Netman will call out to it to inform it that the buffer for the `uri` was closed.

> Sounds pretty cool, but

### How the heck does the api work?

The api is the main "guts" of Netman. It sits between `neovim` (and therefore the end user) and the `provider`. Both of them communicate with it via a standard set of functions, and this allows the api to communicate "between" them in an abstract way (so the end user doesn't have to care how to interface with a protocol and the provider doesn't have to care about how to interface with a user).

> Sounds cool but why would a user talk to Netman instead of neovim?

The best part of all of this is that Netman's api cleanly integrates itself into `neovim` and thus the user (and `neovim`) don't have to care about how to talk to it. The user will simply utilize `neovim` as they would regularly do, except Netman provides additional functionality to interface with remote data via the provider structure. When a user opens a remote location (via `uri`), Netman will take over and ensure a clean experience between the user and the provider.

> How does Netman do that?

Netman has the following events set for providers that are registered with it
- [`FileReadCmd`](https://neovim.io/doc/user/autocmd.html#FileReadCmd)
    - This `autocommand` is used to capture when `neovim` is opening a file with a protocol that Netman supports.
- [`BufReadCmd`](https://neovim.io/doc/user/autocmd.html#BufReadCmd)
    - This `autocommand` is used to capture when `neovim` is opening a buffer with a protocol that Netman supports.
- [`FileWriteCmd`](https://neovim.io/doc/user/autocmd.html#FileWriteCmd)
    - This `autocommand` is used to capture when the user is writing out to a file (before the write occurs) for a buffer that Netman is watching.
- [`BufWriteCmd`](https://neovim.io/doc/user/autocmd.html#BufWriteCmd)
    - This `autocommand` is used to capture when the user is writing out their buffer (before the write occurs), when the buffer is one that Netman is watching
- [`BufUnload`](https://neovim.io/doc/user/autocmd.html#BufUnload)
    - This `autocommand` is used to capture when a relevant buffer is being closed by the user. Netman will reach out to the associated provider to inform it that the buffer is being closed

When a `ReadCmd` event is fired, Netman forwards the associated `uri` to its `read` command, where the api establishes which provider should handle the read, and then provides the results from the provider to the user. [This is laid out more in the api documentation](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#readbuffer_index-path)

Additionally, Netman _does_ expose a vim command `:Nmread` which directs to the `read` api. This _can_ be used by the user but is more meant for **you** the developer.

When a `WriteCmd` event is fired, Netman forwards the associated `uri` to its `write` command, where the api grabs the cached provider and informs it that the user wishes to write out their buffer to this uri. [More details on how `write` works is explained in the api documentation](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#writebuffer_index-write_path)

Additionally, Netman _does_ expose a vim command `:Nmwrite` which directs to the `write` api. This _can_ be used by the user but is more meant for **you** the developer.

> There is a lot of talk about providers

### What is a provider?

A provider is a program that sits between Netman and an external data source that is not reachable in "traditional" means. An example of a provider is the [builtin ssh provider, `netman.providers.ssh`](https://github.com/miversen33/netman.nvim/blob/main/lua/netman/providers/ssh.lua). In this case, the `ssh` provider sits between Netman and `ssh` related programs (`ssh`, `sftp`, `scp`), and since it has implemented the required provider interface, `api` is able to safely assume that it can be communicated with to gather information from the various `ssh` related programs when a user requests to do so (with a `uri`, such as `sftp://myhost/my/super/secret/file`).

A provider should return consistent data (as declared in the [api documentation](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#readbuffer_index-path)), though it does not have to store anything within the local filesystem.

> That sounds pretty cool but Netman doesn't support X protocol.

## How to create a provider!

So you want to create a provider for `protocol X`? You've come to the right place! We are going to be creating a provider for [`docker`](https://www.docker.com/), follow along!

Before we get started, ensure that you have `netman` installed! [Head back to the README for more details on how to install netman if you have forgotten how!](https://github.com/miversen33/netman.nvim)

### Initial Considerations

Before we can begin creating our shiny new provider, we need to take a few things into consideration.

First! Have we searched for providers that might do what we are looking for on [github](https://github.com/topics/netman)? It could be that a provider exists to handle `X` protocol. If not (or you feel like making your own anyway), onto the second question

Second! What is the target program(s) of our provider? For `docker`, we care about the `docker` program. Thus, we will need to ensure that `docker` exists when the provider is initialized, and if it doesn't exist, we should _not_ intialize (along with log) that we were not able to find all our dependencies. This is critical for users when they are expecting to be able to use a provider and it isn't present. The inevitable `"It didn't work"` can be prevented with proper error handling and communication with the user on when your dependencies aren't met.

Third! What edge cases might we run into while communicating with our program (`docker` in this case), and how will we handle them? It is important to know what _might_ go wrong beforehand and ensure that we account for those scenarios, or at the very least call them out so the `user` has some point of reference upon errors.
In `docker's` case, the following considerations need to be accounted for
- Docker isn't installed
    - In this case, we should simply not initialize (this is covered more below)
- The target container doesn't exist
    - In this case, we should simply reject (return `nil`) any requests to this container, as well as notify the user that their request is nonsensical.
- The target container isn't running
    - Here, we can handle this in one of 3 ways
        - We can die and error out that the container isn't running
        - We can prompt the user to see if we should attempt to start the container
        - We can attempt to autostart the container
- The target container doesn't have the appropriate programs installed for introspection
    - Our preferred method of traversing the file system will be to execute `find` within the container (much like we do in the `ssh` provider). This should be available on _most_ containers but it might not be. If this is the case, we can do one of the following options
        - We can die and complain that we can't properly introspect the container
        - We can try a fallback program for introspection (such as `ls`)
        - We can try utilizing docker tools to externally interface with the container contents

With these considerations in mind (and valid research done), lets dive into creating our new provider!

#### First Steps

The first thing to do is create a new repo for our provider (`docker` will be included in the `Netman` core but for the sake of this guide, we will create a new repository)

```shell
$ git init docker-provider-netman
Initialized empty Git repository in /home/miversen/git/docker-provider-netman/.git/
```

There is no specific naming convention for providers, name your provider whatever you would like!

Once we have our `provider` repo started, lets enter the directory and create the following file structure

```shell
$ cd docker-provider-netman
$ mkdir -p lua/docker-provider-netman
$ cd lua/docker-provider-netman
$ touch init.lua
```
Here we are creating the basic `lua` file structure that `neovim` will be looking for when a user attempts to import our plugin.
At this point, your project should look something like this
```shell
❯ ls -R docker-provider-netman 
.:
lua

./lua:
docker-provider-netman

./lua/docker-provider-netman:
init.lua
```

Or more clearly
```
> lua
    > docker-provider-netman
        > init.lua
```

Lets add the `init.lua` (in its current blank form) to the repo
```shell
$ git add init.lua
```

We can verify that the file has been added via
```shell
$ git status
On branch master

No commits yet

Changes to be committed:
  (use "git rm --cached <file>..." to unstage)
        new file:   init.lua
```

Lets stage and commit it so we have a safe fallback when we are working!
```shell
$ git stage init.lua
$ git commit -m "Initial Filestructure"
[master (root-commit) 64aacb6] Initial Filestructure
 1 file changed, 0 insertions(+), 0 deletions(-)
 create mode 100644 lua/docker-provider-netman/init.lua
 ```
 You should get something like the above. If you are having issues with working through git, [atlassian](https://www.atlassian.com/git) provides a very helpful walk through of how git works and how to use it. If you are just getting started on Neovim and/or lua development, [`nanotree`](https://github.com/nanotee/nvim-lua-guide) has created an excellent guide! Moving forward, we will focus on the development of the plugin and less on the stuff going on around it (meaning, there won't be more shell commands or explanations about git/shell)

To make it so that `neovim` will load our new provider into memory during startup, lets link our project to `neovim's` runtime directory
```shell
$ ln -s $HOME/git/docker-provider-netman/ $HOME/.local/share/nvim/site/pack/plugins/opt/docker-provider-netman/
```
**Note: If you use a plugin manager, consult your plugin manager on how to load local plugins**

#### Creating our basic provider structure

Lets create another lua file (in the same location as `init.lua`)
```shell
$ touch docker.lua
```
This is where we will put the logic for our provider!

[The Netman API calls the following attributes that must be defined on every provider](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#providers-1)
- read
- write
- delete
- get_metadata
- protocol_patterns
- name
- version

It also calls out the following optional functions
- init
- close_connection

Failure to declare any of these attributes will result in the Netman api failing to import our provider! To demonstrate this, lets setup our provider to be loaded by Netman. Add the following code to your `init.lua`
```lua
-- init.lua
vim.g.netman_log_level = 1
local docker_provider = "docker-provider-netman.docker"
require("netman.api"):load_provider(docker_provider)
```
Before we can test our code, lets get the logs opened up so we can see what is happening. Netman logs can be found in `$HOME/.local/share/nvim/netman/logs.txt`
Open a shell and tail the file
```shell
$ tail -f $HOME/.local/share/nvim/netman/logs.txt
```

And then from your neovim editor, run the following command
```vim
:luafile init.lua
```

You will be greeted with lots of errors! You can see them both in `neovim`
```
"Failed to initialize provider: docker-provider-netman.docker. This is likely due to it not being loaded into neovim correctly. Please ensure you have installed this plugin/provider"
E5113: Error while calling lua chunk: .../site/pack/packer/start/netman.nvim/lua/netman/utils.lua:242: "Failed to initialize provider: docker-provider-netman.docker. This is likely due to it not being loaded into neovim correctly. Please ensure you have installed this plugin/provider"
stack traceback:
        [C]: in function 'error'
        .../site/pack/packer/start/netman.nvim/lua/netman/utils.lua:242: in function '_log'
        .../site/pack/packer/start/netman.nvim/lua/netman/utils.lua:279: in function 'error'
        ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:414: in function 'load_provider'
```

As well as the Netman log!
```
[2022-04-26 22:34:29] [SID: rwqmhmpzqjfhzne] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:412 "Attempting to import provider: docker-provider-netman.docker"  {
  status = false
}
[2022-04-26 22:34:29] [SID: rwqmhmpzqjfhzne] [Level: ERROR]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:414 "Failed to initialize provider: docker-provider-netman.docker. This is likely due to it not being loaded into neovim correctly. Please ensure you have installed this plugin/provider"
```

The netman logs will be critical in working through the various errors we will encounter on this journey. For more details on troubleshooting, head over to [how to troubleshoot your shiny new provider](#how-to-troubleshoot-your-shiny-new-provider)

#### So what happened?
Why did we get the above errors? What is the code we put in `init.lua` doing? What to do the logs mean Mason?!
Lets close neovim and review the above sections
**Note: Due to how lua imports packages, a close and reopen of neovim is required for each import. Work is being done to allow Netman to help alleviate this process**

Lets start with the code above
```lua
-- init.lua
vim.g.netman_log_level = 1
local docker_provider = "docker-provider-netman.docker"
require("netman.api"):load_provider(docker_provider)
```
These 3 lines are doing the following
```lua
vim.g.netman_log_level = 1
```
We are setting the netman log level to level 1 (DEBUG mode). Log levels for Netman range from 1-4 (as laid out in [troubleshooting steps](#how-to-troubleshoot-your-shiny-new-provider)). Setting it to 1 means we will get _a lot_ of logs which is quite helpful when we are creating a new provider! Just remember to remove this line before putting your code in production or users will have _lots_ of logs!
```lua
local docker_provider = "docker-provider-netman.docker"
require("netman.api"):load_provider(docker_provider)
```
Here we are telling `netman.api`'s [`load_provider`](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#load_providerprovider_path) function to load our new provider "docker-provider-netman.docker". When we load our provider into Netman, the string that is provided _should_ be the same string that an end user would use to `require` our provider, as that is exactly what Netman does!

So now that we know what the code is doing (vaguely), what do the errors mean?
The main log
```
"Failed to initialize provider: docker-provider-netman.docker. This is likely due to it not being loaded into neovim correctly. Please ensure you have installed this plugin/provider"
```
Is displayed to indicate to the user that the listed provider (`docker-provider-netman.docker`) is not a valid provider. This is correct, as our provider does not implement the [above listed](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#providers-1) requirements to be considered a `Netman compatible provider™`

Lets `stub` these functions and variables so that we can begin development within Netman
```lua
-- init.lua
vim.g.netman_log_level = 1
local docker_provider = "docker-provider-netman.docker"
require("netman.api"):load_provider(docker_provider)
```

[`docker.lua`](https://github.com/miversen33/netman.nvim/blob/0c70ae6ef32675c4f90c6f3b383c484e23f631f7/lua/netman/providers/docker.lua)
```lua
-- docker.lua
local M = {}

M.protocol_patterns = {}
M.name = 'docker'
M.version = 0.1

function M:read(uri, cache)

end

function M:write(buffer_index, uri, cache)

end

function M:delete(uri)

end

function M:get_metadata(requested_metadata)

end

function M:init(config_options)

end

function M:close_connection(buffer_index, uri, cache)

end

return M
```

Rerunning our require
```vim 
:luafile init.lua
```

> We now don't see any errors! Success right?!

Unfortunately not. If we check the Netman logs, you will see the following lines

```
[2022-04-26 22:57:22] [SID: wqdzzelrxombbco] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:412 "Attempting to import provider: docker-provider-netman.docker"  {
  status = true
}
[2022-04-26 22:57:22] [SID: wqdzzelrxombbco] [Level: INFO]   -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:422 "Validating Provider: docker-provider-netman.docker"
[2022-04-26 22:57:22] [SID: wqdzzelrxombbco] [Level: INFO]   -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:433 "Validation finished"
[2022-04-26 22:57:22] [SID: wqdzzelrxombbco] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:445 "Initializing docker-provider-netman.docker:0.1"
[2022-04-26 22:57:22] [SID: wqdzzelrxombbco] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:447 "Found init function for provider!"
[2022-04-26 22:57:22] [SID: wqdzzelrxombbco] [Level: WARN]   -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:450 "docker-provider-netman.docker:0.1 refused to initialize. Discarding"
```
> What gives?!

Reading through the logs, we can see a handful of things going on here. Netman _did_ successfully import the provider, as shown by "`Validation finished`". However, the last line is what throws us off. Why did Netman refuse to load our provider? "`docker-provider-netman.docker:0.1 refused to initialize. Discarding`"

This was thrown because we created the optional _init_ method and did not return anything from it. Thus when Netman checked to see if it can use us, we did _not_ say yes and therefore it assumes _no_ the `docker` provider is not ready to be used, and discards us. This is a safeguard in place to ensure that if a provider has initialization to perform, it is able to tell us it is indeed ready to move forward. Failure to inform Netman you are ready results in being discarded so as to not accidentally call you when you are not usable. The [API Doc](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#initconfiguration_options) puts it well
> Should return a true/false depending on if the provider was able to properly initialize itself

As we did _not_ return true, initialization is considered a failure. For now, lets add a `return true` to the bottom of our init function in `docker.lua`

[`docker.lua`](https://github.com/miversen33/netman.nvim/blob/7e7edde58d0216cf432b9d43f3f7566afaddd7f2/lua/netman/providers/docker.lua)
```lua
local M = {}

M.protocol_patterns = {}
M.name = 'docker'
M.version = 0.1

function M:read(uri, cache)

end

function M:write(buffer_index, uri, cache)

end

function M:delete(uri)

end

function M:get_metadata(requested_metadata)

end

function M:init(config_options)

    return true
end

function M:close_connection(buffer_index, uri, cache)

end

return M
```

When we run it this time
```
:luafile init.lua
```

We will get the following output
```
[2022-04-26 23:06:26] [SID: uhrhnkjctoymgwt] [Level: INFO]   -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:422 "Validating Provider: docker-provider-netman.docker"
[2022-04-26 23:06:26] [SID: uhrhnkjctoymgwt] [Level: INFO]   -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:433 "Validation finished"
[2022-04-26 23:06:26] [SID: uhrhnkjctoymgwt] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:445 "Initializing docker-provider-netman.docker:0.1"
[2022-04-26 23:06:26] [SID: uhrhnkjctoymgwt] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:447 "Found init function for provider!"
[2022-04-26 23:06:26] [SID: uhrhnkjctoymgwt] [Level: INFO]   -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:515 "Initialized docker-provider-netman.docker successfully!"
```
Success!
Netman accepted our provider! We are now ready to move into interfacing with Docker and the Netman API

### Integration with api
#### Implementing Init
##### Reference Points
- [vim.fn.jobstart](https://neovim.io/doc/user/builtin.html#jobstart())
- [docker](https://docs.docker.com/engine/)
- [command](https://man7.org/linux/man-pages/man1/command.1p.html)

> So with Netman accepting our provider, we are ready to begin editing docker uris right?!

Not exactly. We are missing 2 key things before the user can utilize our provider
- We haven't defined any protocol patterns yet
- [We should look back at our considerations earlier](#initial-considerations)
> In `docker's` case, the following considerations need to be accounted for
> - Docker isn't installed

Addressing the first `We haven't defined any protocol patterns yet`, if we have not defined protocol patterns, Netman will accept our initialization but wont link protocols to our provider to consume. If you try to open a docker uri (something like `docker://somecontainer/somepath`), a new vim buffer will be opened for this uri, but it will be considered a file and our provider will _not_ be called. To verify this, consider the following change to the `read` function in our `docker.lua` file
```lua
-- docker.lua
function M:read(uri, cache)
    require("netman.utils").log.debug("Loading Docker URI!")
end
```
Upon save and neovim reload with, try editing the above URI.
You will see `neovim` happily open a new file called `somepath` and our logs do not show any attempt to reach the docker provider we gave it!

So what happened? Why did our provider _not_ get called like we expected?
During the `load_provider` call we do in `init`, Netman is reading the contents of our `protocol_patterns` array. Which, as we declared above, is completely empty
```lua
-- docker.lua
M.protocol_patterns = {}
```
Thus, while Netman _did_ accept our provider, it did not register any protocols to us. To fix that, lets get a pattern added to our protocol patterns
```lua
-- docker.lua
M.protocol_patterns = {'docker'}
```
**Note: As called out in the [API Documentation](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#protocol_patterns), do _not_ use a glob for the protocol handler here. Simply list the protocol you are interested in, Netman will handle creating the proper glob for it**
> protocol_patterns should be an array of the various protocols (not blobs) that the provider supports.

If we reload Neovim _again_ we will now see the following log
```
[2022-04-26 23:24:19] [SID: yoactdtovslrwdu] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:412 "Attempting to import provider: docker-provider-netman.docker"  {
  status = true
}
[2022-04-26 23:24:19] [SID: yoactdtovslrwdu] [Level: INFO]   -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:422 "Validating Provider: docker-provider-netman.docker"
[2022-04-26 23:24:19] [SID: yoactdtovslrwdu] [Level: INFO]   -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:433 "Validation finished"
[2022-04-26 23:24:19] [SID: yoactdtovslrwdu] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:445 "Initializing docker-provider-netman.docker:0.1"
[2022-04-26 23:24:19] [SID: yoactdtovslrwdu] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:447 "Found init function for provider!"
[2022-04-26 23:24:19] [SID: yoactdtovslrwdu] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:462 "Reducing docker down to docker"
[2022-04-26 23:24:19] [SID: yoactdtovslrwdu] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:507 "Augroup Netman already exists, not recreating augroup"
[2022-04-26 23:24:19] [SID: yoactdtovslrwdu] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:510 'Setting Autocommand: autocmd Netman FileReadCmd docker://* lua require("netman"):read(vim.fn.expand("<amatch>"))'
[2022-04-26 23:24:19] [SID: yoactdtovslrwdu] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:510 'Setting Autocommand: autocmd Netman BufReadCmd docker://* lua require("netman"):read(vim.fn.expand("<amatch>"))'
[2022-04-26 23:24:19] [SID: yoactdtovslrwdu] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:510 'Setting Autocommand: autocmd Netman FileWriteCmd docker://* lua require("netman"):write()'
[2022-04-26 23:24:19] [SID: yoactdtovslrwdu] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:510 'Setting Autocommand: autocmd Netman BufWriteCmd docker://* lua require("netman"):write()'
[2022-04-26 23:24:19] [SID: yoactdtovslrwdu] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:510 'Setting Autocommand: autocmd Netman BufUnload docker://* lua require("netman.api"):unload(vim.fn.expand("<abuf>"))'
[2022-04-26 23:24:20] [SID: yoactdtovslrwdu] [Level: INFO]   -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:515 "Initialized docker-provider-netman.docker successfully!"
```

Here we can see the usual logs we saw earlier about initialization, but there are **new** logs being output now! Logs about connecting `docker://*` to Netman!

If we try to edit the above `docker://somecontainer/somepath`
```
:edit docker://somecontainer/somepath
```

we will see the following logs

```
[2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: WARN]   -- ...m/site/pack/packer/start/netman.nvim/lua/netman/init.lua:12  "Fetching file: docker://somecontainer/somepath"
[2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: INFO]   -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:173 "No cache table found for index: 1. Creating one now"
[2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:177 "No cache object associated with protocol: docker for index: 1. Attempting to claim one"
[2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: INFO]   -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:84  "Selecting provider: docker-provider-netman.docker:0.1 for path: docker://somecontainer/somepath"
[2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:137 "Reaching out to provider: docker-provider-netman.docker:0.1 to initialize connection for path: docker://somecontainer/somepath"
[2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:150 "Cached provider: docker-provider-netman.docker:0.1 for id: ypqjtahgej"
[2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:188 "Claiming ypqjtahgej and associating it with index: 1"
[2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:211 "Claimed ypqjtahgej and associated it with 1"
[2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:214 "Removed unclaimed details for ypqjtahgej"
[2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: DEBUG]  -- ...er-provider-netman/lua/docker-provider-netman/docker.lua:8   "Loading Docker URI!"
[2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: INFO]   -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:303 "Setting read type to api.READ_TYPE.STREAM"
[2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: DEBUG]  -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:304 "back in my day we didn't have optional return values..."
[2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: INFO]   -- ...im/site/pack/packer/start/netman.nvim/lua/netman/api.lua:313 "Received nothing to display to the user, this seems wrong but I just do what I'm told..."
[2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: WARN]   -- ...m/site/pack/packer/start/netman.nvim/lua/netman/init.lua:15  "No command returned for read of docker://somecontainer/somepath"
```

> [2022-04-26 23:26:32] [SID: htsmyzufhpjsgkd] [Level: DEBUG]  -- ...er-provider-netman/lua/docker-provider-netman/docker.lua:8   "Loading Docker URI!"

**Success!** We can now see that our `read` function was called

However, we still have our second point to handle.
> [We should look back at our considerations earlier](#initial-considerations)
> . In `docker's` case, the following considerations need to be accounted for
> - Docker isn't installed

We haven't checked to ensure that our provider can actually be useful to the end user, so lets do that!

In our case, we simply need to ensure that the `docker` command is available on our path ([and that the user can execute it](https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user)).

Lets look at how we might check if the docker command is available and usable _outside_ the Netman framework.

If `docker` exists, using the [`command`](https://man7.org/linux/man-pages/man1/command.1p.html) shell function will give us the following output
```shell
$ command -v docker; echo $?
/usr/bin/docker
0
```
**Note: `echo $?` is printing out the exit code from command. 0 is a success here**

If `docker` doesn't exist, the function will give us the following output
```shell
$ command -v docker; echo $?
1
```
Notice that here we do not get any `STDOUT` from the command, and the exit code is 1? This means that `docker` is not available on the path. This is a great way for us to check if docker is installed, we can execute the above line and consume `STDOUT`.

Great! So we have a command we can run, lets get that put in our `init` function!
```lua
function M:init(config_options)
    local command = 'command -v docker' -- command we are going to run as discussed above
    local stdout = {} -- empty table to capture standard output from vim.fn.jobstart
    local stderr = {} -- empty table to capture standard error from vim.fn.jobstart
    vim.fn.jobwait({vim.fn.jobstart(command, {
        on_stdout = function(job_id, output) for _, line in ipairs(output) do table.insert(stdout, line) end end,
        on_stderr = function(job_id, output) for _, line in ipairs(output) do table.insert(stderr, line) end end
    })}) -- Run job, capture output from standard out and standard error, and wait for job to finish
    local error = table.concat(stderr, '') -- Merge stderr into a string
    local docker_path = table.concat(stdout, '') -- Merge stdout into a string
    if error ~= '' or docker_path == '' then -- If we got an error or _didn't_ get stdout, we need to fail
        require("netman.utils").notify.error("Unable to verify docker is available to run!")
        if error ~= '' then require("netman.utils").log.warn("Found error during check for docker: " .. error) end
        if docker_path == '' then require("netman.utils").log.warn("Docker was not found on path!") end
        return false
    end
    -- Success!
    require("netman.utils").log.info("Docker found at '" .. docker_path .. "'!")
    return true
end
```

The above is certainly a mouthful. It is worth looking at alternative tools for command interfacing such as [`netman.utils`](https://github.com/miversen33/netman.nvim/wiki/API-Documentation) or the fantastic [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)

Below is a cleaned up way of doing this with the provided tools in `netman.utils`
```lua
function M:init(config_options)
    local command = 'command -v docker'
    local command_flags = require("netman.options").utils.command
    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''
    command_options[command_flags.STDOUT_JOIN] = ''
    local command_output = require("netman.utils").run_shell_command(command, command_options)
    local docker_path, error = command_output.stdout, command_output.stderr
    if error ~= '' or docker_path == '' then
        require("netman.utils").notify.error("Unable to verify docker is available to run!")
        if error ~= '' then require("netman.utils").log.warn("Found error during check for docker: " .. error) end
        if docker_path == '' then require("netman.utils").log.warn("Docker was not found on path!") end
        return false
    end
    require("netman.utils").log.info("Docker found at '" .. docker_path .. "'!")
    return true
end
```

With the above in place, we can now safely assume that if Netman is interfacing with us, our dependencies are available for us. It is also worth logging out relevant information for future use. Below is the finished product of the `init` function
[`docker.lua`](https://github.com/miversen33/netman.nvim/blob/41bbd55379cbd2122fb5c2f5326d92baf6a371d7/lua/netman/providers/docker.lua)
```lua
-- docker.lua
local log = require("netman.utils").log
local notify = require("netman.utils").notify
local shell = require("netman.utils").run_shell_command
local command_flags = require("netman.options").utils.command

local invalid_permission_glob = '^Got permission denied while trying to connect to the Docker daemon socket at'
-- Rest of file
function M:init(config_options)
    local command = 'command -v docker'
    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''
    command_options[command_flags.STDOUT_JOIN] = ''

    local command_output = shell(command, command_options)
    local docker_path, error = command_output.stdout, command_output.stderr
    if error ~= '' or docker_path == '' then
        notify.error("Unable to verify docker is available to run!")
        if error ~= '' then log.warn("Found error during check for docker: " .. error) end
        if docker_path == '' then log.warn("Docker was not found on path!") end
        return false
    end

    local docker_version_command = "docker -v"
    command_output = shell(docker_version_command, command_options)
    if command_output.stdout:match(invalid_permission_glob) then
        notify.error("It appears you do not have permission to interact with docker on this machine. Please view https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user for more details")
        log.info("Received invalid docker permission error: " .. command_output.stdout)
        return false
    end
    if command_output.stderr ~= '' or command_output.stdout == '' then
        notify.error("Invalid docker version information found!")
        log.info("Received Docker Version Error: " .. command_output.stderr)
        return false
    end
    log.info("Docker path: '" .. docker_path .. "' -- Version Info: " .. command_output.stdout)
    return true
end
-- Rest of file
```

#### Implementing Read

So we have implemented our `init` function, we should next consider the main use of any provider, the `read` function.

There are 3 types of `read` events to consider. These are
- [Streams](https://github.com/miversen33/netman.nvim/wiki/API-Documentation)
- [Files](https://github.com/miversen33/netman.nvim/wiki/API-Documentation)
- [Directories](https://github.com/miversen33/netman.nvim/wiki/API-Documentation)

##### Read Streams
When working within a remote filesystem, you as the provider may wish to return information to the user that is not from a file. This could be live results from a socket read, query results from a database query, dynamically generated content, etc. In these events, Netman provides a read type just for you! The [`READ_TYPE.STREAM`]((https://github.com/miversen33/netman.nvim/wiki/API-Documentation)) type. If you are working with a stream, be sure to follow the [`API Documentation`](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#readuri-cache) for how to return these read types

##### Read Files
Of course we have a more traditional [`READ_TYPE.FILE`](https://github.com/miversen33/netman.nvim/wiki/API-Documentation) as well, with documentation on how to utilize it found within the [`API Documentation`](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#readuri-cache).

##### Read Directories
In the event that you are reading the contents of a directory, Netman provides a special kind of stream type. The [`READ_TYPE.EXPLORE`](https://github.com/miversen33/netman.nvim/wiki/API-Documentation) is meant for just this purpose, and the `API Documentation`](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#readuri-cache) lays out how to utilize it.

It is wise to familiarize yourself with these 3 types as they are paramount to how Netman `read` operations operate. For our `docker` provider, we will be implementing the [`READ_TYPE.FILE`](https://github.com/miversen33/netman.nvim/wiki/API-Documentation) and [`READ_TYPE.EXPLORE`](https://github.com/miversen33/netman.nvim/wiki/API-Documentation) read types.

##### Read Introspection
Before we dive into how to implement these ([you can skip ahead if you're the impatient type](#docker-read-implementation)), we first need to examine how we would "read" a file and directory within the contents of the program(s) we are interfacing with. For this provider, that is docker.

Lets head back to our shell and weigh our options. Docker providers a `copy` command which seems to be ideal for reading in files for us
```shell
$ docker help
...
Commands:
...
  cp          Copy files/folders between a container and the local filesystem
...
```
This will work perfectly for us for reading and writing files, but what about directories? Docker doesn't provide a smooth/clean way for us to do this so we will have to consider a few choices.
- We can utilize the [`find`]() command
- We can utilize the `docker container export` command to dump the container to a local `tar` file and introspect that

There are additional considerations to make in this situation. [`Our initial considerations`](#initial-considerations) will be key here as well
> - The target container doesn't exist
>     - In this case, we should simply reject (return `nil`) any requests to this container, as well as notify the user that their request is nonsensical.
> - The target container isn't running
>     - Here, we can handle this in one of 3 ways
>         - We can die and error out that the container isn't running
>         - We can prompt the user to see if we should attempt to start the container
>         - We can attempt to autostart the container

We will also need to address the container state before attempting to read. **For simplicity sake, we are going to implement our provider to _only_ handle if the container exists, and if the container has our dependencies (`find`/`ls`, `rm`).

The last thing we will need to do is _parse_ the URI to get the required components we will need for our container.
This is a pretty simple (albeit longish) process, and this is where we are going to start with our code.

##### Parsing URI
To parse a URI, we have to set rules on what a `URI` for our provider will look like. For details on what this can look like, we can refer back to the [`main page README`](https://github.com/miversen33/netman.nvim#ssh) as it calls out a `URI spec` for the [`ssh`](https://github.com/miversen33/netman.nvim/blob/main/lua/netman/providers/ssh.lua) provider 
> $PROTOCOL://[$USERNAME@]$HOSTNAME[:$PORT]/[//][$PATH]

In the case of `docker` we wont care about the middle section much, so lets refactor this a bit to fit our needs
> $PROTOCOL://$CONTAINER/[//]$PATH

This is pretty clean and tells the user exactly how to access our provider. `Netman` does _not_ enforce `URI` conventions on the provider, aside from requiring the provider to specify its `$PROTOCOL(S)` that it handles. This means we as the provider will need to verify that a `URI` contains the relevant info.
We can _actually_ just "borrow" and modify the code used in the `ssh` provider for this as it does a great job at handling `URI` validation. Below is what that code would look like, retrofitted to handle our above `docker uri` spec.
```lua
-- docker.lua
-- beginning of file
function M:read(uri, cache)
    local details = {
        base_uri     = uri
        ,command     = nil
        ,protocol    = nil
        ,container   = nil
        ,path        = nil
        ,file_type   = nil
        ,return_type = nil
        ,parent      = nil
        ,local_file  = nil
    }
    details.protocol = uri:match('^(.*)://')
    uri = uri:gsub('^(.*)://', '')
    details.container = uri:match("^([%a%c%d%s%-_%.]*)") or ''
    uri = uri:gsub("^([%a%c%d%s%-_%.]*)", '')
    local path_head, path_body = uri:match('^([/]+)(.*)$')
    path_body = path_body or ""
    if (path_head:len() ~= 1) then
        require("netman.utils").notify.error("Error parsing path: Unable to parse path from uri: " .. details.base_uri .. '. Path should begin with / but path begins with ' .. path_head)
        return nil
    end
    details.path = "/" .. path_body
    if details.path:sub(-1) == '/' then
        details.file_type = require("netman.options").api.ATTRIBUTES.DIRECTORY
        details.return_type = require("netman.options").api.READ_TYPE.EXPLORE
    else
        details.file_type = require("netman.options").api.ATTRIBUTES.FILE
        details.return_type = require("netman.options").api.READ_TYPE.FILE
        details.unique_name = require("netman.utils").string_generator(11)
        details.local_file  = local_files .. details.unique_name
    end
    local parent = ''
    local previous_parent = ''
    local cur_path = ''
    for i=1, #details.path do
        local char = details.path:sub(i,i)
        cur_path = cur_path .. char
        if char == '/' then
            previous_parent = parent
            parent = parent .. cur_path
            cur_path = ''
        end
    end
    if cur_path == '' then parent = previous_parent end
    details.parent = parent
    require("netman.utils").log.debug("Parsed URI Down To ", {uri_details=details})
end
-- rest of file
```

Lets try reading in a uri within docker!
```
:edit docker://somecontainer/some/file/
```

The above will print out a the following useful log
```
[2022-05-01 08:55:46] [SID: xontjzbluswajbx] [Level: DEBUG]  -- ...er-provider-netman/lua/docker-provider-netman/docker.lua:133    "Parsed URI Down To "   {
  uri_details = {
    base_uri = "docker://somecontainer/some/file/",
    container = "somecontainer",
    parent = "/root/some/",
    path = "/root/some/file/",
    protocol = "docker",
    return_type = "EXPLORE",
    type = "DIRECTORY"
  }
}
```

This is fantastic as it shows that our `URI` parsing worked, however it may also look like straight up black magic so lets break down what is happening before we move forward

###### Understanding URI Parsing
To begin, it is advised that you familiarize yourself with [`lua's string library`](https://www.lua.org/pil/20.html), in particular the [`pattern processing section`](https://www.lua.org/pil/20.1.html).
Once you have become a `pattern processing god`, lets move into how to pull apart the `URI` as we did above and explain what each section is doing.

**Note: This section will _not_ explain how globs work, please review the above links before diving into this**

As we do _not_ have a regex library in lua (and globbing _should_ be faster than `vim` regex), we are going to do a `find-and-replace` form of string parsing. To do this, we want to consume the input string from left to right and replace what we use with a blank 0 length char (`''`).
First lets start with getting the protocol!
```lua
    local details = {
        base_uri     = uri
        ,command     = nil
        ,protocol    = nil
        ,container   = nil
        ,path        = nil
        ,file_type   = nil
        ,return_type = nil
        ,parent      = nil
        ,local_file  = nil
    }
    details.protocol = uri:match('^(.*)://')
    uri = uri:gsub('^(.*)://', '')
```
Notice that we initially store the `URI` as the `base_uri` variable in our `details` table? You can of course name this variable whatever you want, but as we are going to be modifying the `URI` below, it makes sense to cache the original for later viewing/use. Next we pattern match our protocol out of the `uri` string and we store it in the `details` table. Finally, we replace the matched `protocol` with an empty char (`''`).
We will following this `find-and-replace` pattern throughout the entire URI. Lets move onto getting the container name
```lua
    details.container = uri:match("^([%a%c%d%s%-_%.]*)") or ''
    uri = uri:gsub("^([%a%c%d%s%-_%.]*)", '')
```
Notice that again we are consuming everything from the beginning of the line up through some defined end? This is because we replaced the `protocol` (the previous beginning of the line) with `''`, which allows us to continue picking off the front of the string.
Finally, lets get the path
```lua
    local path_head, path_body = uri:match('^([/]+)(.*)$')
```
We refrain from putting the full path into the `details` table as we have for the other components as we have a bit of post processing to do on the string first. Below we are going to do a handful of things, each will be broken out and explained in chunks.
```lua
    path_body = path_body or ""
    if (path_head:len() ~= 1) then
        require("netman.utils").notify.error("Error parsing path: Unable to parse path from uri: " .. details.base_uri .. '. Path should begin with / but path begins with ' .. path_head)
        return nil
    end
    details.path = "/" .. path_body
```
1) We are setting a default value for `path_body` if it wasn't found in the above string parsing
2) We are validating that the `path_head` matches our desired `/` or `///` path lead, as called out in our protocol spec.

```lua
    if details.path:sub(-1) == '/' then
        details.file_type = require("netman.options").api.ATTRIBUTES.DIRECTORY
        details.return_type = require("netman.options").api.READ_TYPE.EXPLORE
    else
        details.file_type = require("netman.options").api.ATTRIBUTES.FILE
        details.return_type = require("netman.options").api.READ_TYPE.FILE
        details.unique_name = require("netman.utils").string_generator(11)
        details.local_file  = require("netman.utils").files_dir .. details.unique_name
    end
```
If the end of the `path` object is `/`, we are assuming that the path is a `DIRECTORY` and set its `type` accordingly. This will be important for [`exploring directories`]() later.
If the end of the `path` is _not_ `/`, we assume that the path is a `FILE` and set its `type` accordingly. Additionally in our case (as the `docker` provider), we are generating a `unique` name for the local file we are going to pull down later. We then set the absolute path for the `local_file` we will be creating later. This will be useful when we pull the file down from `docker`.

The last chunk of the above logic
```lua
    local parent = '' -- The cache parent string we are going to use
    local previous_parent = '' -- The previous parent string. Used when changing the parent
    local cur_path = '' -- The current point in our path traversal
    for i=1, #details.path do -- Iterate through each character in our path
        local char = details.path:sub(i,i) -- Get the single character at index `i`
        cur_path = cur_path .. char -- Build the current path
        if char == '/' then -- If the path ends in a `/`, update the previous parent 
                            -- to be whatever the current parent is, update the 
                            -- current parent is, append the `cur_path` string
                            -- to the parent and reset the `cur_path`
            previous_parent = parent
            parent = parent .. cur_path
            cur_path = ''
        end
    end
    if cur_path == '' then parent = previous_parent end 
    -- If the `cur_path` is `''`, then the `cur_path` ended in `/`. Put `parent` back
    -- to the `previous_parent` to ensure we get the _actual_ parent
    details.parent = parent
```
This might be a bit hard to read so instead of explaining it, I have instead commented each line.

From here, we end up with the below table
```lua
uri_details = {
    base_uri = "docker://somecontainer/some/file/",
    container = "somecontainer",
    parent = "/root/some/",
    path = "/root/some/file/",
    protocol = "docker",
    return_type = "EXPLORE",
    type = "DIRECTORY"
}
```
which is exactly what we want! Lets clean up the above code to be more manageable
[`docker.lua`](https://github.com/miversen33/netman.nvim/pull/47/commits/473284f5dd4eca52e9ac8af17fe1a8a2b3c74246)
```lua
-- docker.lua
local log = require("netman.utils").log
local notify = require("netman.utils").notify
local shell = require("netman.utils").run_shell_command
local command_flags = require("netman.options").utils.command
local api_flags = require("netman.options").api
local string_generator = require("netman.utils").generate_string
local local_files = require("netman.utils").files_dir

local invalid_permission_glob = '^Got permission denied while trying to connect to the Docker daemon socket at'

local container_pattern     = "^([%a%c%d%s%-_%.]*)"
local path_pattern          = '^([/]+)(.*)$'
local protocol_pattern      = '^(.*)://'
-- rest of file

--- _parse_uri will take a string uri and return an object containing details about
--- the uri provided.
--- @param uri string
---     A string representation of the uri needing parsed
--- @return table
---     This will either be an empty table (in the event of an error) or a table containing the following keys
---        base_uri
---        ,command
---        ,protocol
---        ,container
---        ,path
---        ,file_type       ,return_type
---        ,parent
local _parse_uri = function(uri)
    local details = {
        base_uri     = uri
        ,command     = nil
        ,protocol    = nil
        ,container   = nil
        ,path        = nil
        ,file_type   = nil
        ,return_type = nil
        ,parent      = nil
        ,local_file  = nil
    }
    details.protocol = uri:match(protocol_pattern)
    uri = uri:gsub(protocol_pattern, '')
    details.container = uri:match(container_pattern) or ''
    uri = uri:gsub(container_pattern, '')
    local path_head, path_body = uri:match(path_pattern)
    path_body = path_body or ""
    if (path_head:len()) then
        notify.error("Error parsing path: Unable to parse path from uri: " .. details.base_uri .. '. Path should begin with / but path begins with ' .. path_head)
        return {}
    end
    details.path = "/" .. path_body
    if details.path:sub(-1) == '/' then
        details.file_type = api_flags.ATTRIBUTES.DIRECTORY
        details.return_type = api_flags.READ_TYPE.EXPLORE
    else
        details.file_type = api_flags.ATTRIBUTES.FILE
        details.return_type = api_flags.READ_TYPE.FILE
        details.unique_name = string_generator(11)
        details.local_file  = local_files .. details.unique_name
    end
    local parent = ''
    local previous_parent = ''
    local cur_path = ''
    for i=1, #details.path do
        local char = details.path:sub(i,i)
        cur_path = cur_path .. char
        if char == '/' then
            previous_parent = parent
            parent = parent .. cur_path
            cur_path = ''
        end
    end
    if cur_path == '' then parent = previous_parent end
    details.parent = parent
    return details
end

function M:read(uri, cache)
    cache = _parse_uri(uri)
    if cache.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. tostring(uri) .. " provided!")
        return nil
    end
end
-- rest of file
```

This is a great start! We can now create a cache object from the provided `uri` which we can utilize to view details about our `uri` object and the details it points to! Next, lets look at how we would handle reading a file.

##### Docker Read Implementation
After we have [parsed our uri](#parsing-uri), we are ready to begin working through how we can read files from `docker`. To do this, we are going to look for the following things
1) Is the container running?
2) Is `find` installed on the container?
3) Is `rm` installed on the container?

As `vim` provides a method of getting user input, we are also going to provide a mechanic for starting the `container` should the user request that (so `1a)`). Lets start with `1a`.

```lua
-- docker.lua
-- rest of file
local _docker_status = {
    ERROR = "ERROR",
    RUNNING = "RUNNING",
    NOT_RUNNING = "NOT_RUNNING"
}
local _is_container_running = function(container)
    local command = 'docker container ls --filter "name=' .. tostring(container) .. '"'
    -- Creating command to check if the container is running
    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''
    -- Options to make our output easier to read

    log.info("Running container life check command: " .. command)
    local command_output = shell(command, command_options)
    local stderr, stdout = command_output.stderr, command_output.stdout
    if stderr ~= '' then
        log.warn("Received error while checking container status: " .. stderr)
        return _docker_status.ERROR
    end
    if stdout[2] == nil then
        log.info("Container " .. container .. " appears to not be running")
        -- Docker container ls (or docker container ps) will always include a header line that looks like
        -- CONTAINER ID   IMAGE               COMMAND                  CREATED       STATUS      PORTS     NAMES
        -- This line is useless to us here, so we ignore the first line of output in stdout. 
        return _docker_status.NOT_RUNNING
    end
    return _docker_status.RUNNING
end

function M:read(uri, cache)
    cache = _parse_uri(uri)
    if cache.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    local container_status = _is_container_running(cache.container)
end
```

Here we are returning a table entry (consider this an `enum`) that will indicate 1 of 3 states the container could be in. We should handle each state on its own, starting with an error state
```lua
function M:read(uri, cache)
--- rest of function
    local container_status = _is_container_running(cache.container)
    if container_status == _docker_status.ERROR then
        notify.error("Unable to find container! Check logs (:Nmlogs) for more details")
        return nil
    end
end
```
Now that we have handled if the client machine threw an error, lets handle if the container _isn't_ running
**NOTE: From this point, we will be using the simple [hello world](https://hub.docker.com/_/hello-world/) container from docker for testing**
```lua
local _start_container = function(container)

end

function M:read(uri, cache)
--- rest of function
    if container_status == _docker_status.NOT_RUNNING then
        log.debug("Getting input from user!")
        vim.ui.input({
            prompt = 'Container ' .. tostring(cache.container) .. ' is not running, would you like to start it? [y/N] ',
            default = 'N'
        }
        , function(input)
            if input:match('^[yYeEsS]$') then
                _start_container(cache.container)
                require("netman"):read(uri)
            elseif input:match('^[nNoO]$') then
                log.info("Not starting container " .. tostring(cache.container))
                return nil
            else
                notify.info("Invalid Input. Not starting container!")
                return nil
            end
        end)
    else
end
```
There isn't a ton to say about what is going on here, we are prompting the user for input on _if_ we should start the not running container and handling their response. 
Lets implement our `_start_container` function next.
[`docker.lua`](https://github.com/miversen33/netman.nvim/blob/10ffa0964b8503e874a2ac972f4d8e12d1087606/lua/netman/providers/docker.lua)
```lua
-- docker.lua
-- rest of file
local _start_container = function(container_name)
    local command = 'docker run "' .. container_name .. '"'

    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''

    log.info("Running start container command: " .. command)
    local command_output = shell(command, command_options)
    log.debug("Container Start Output " , {output=command_output})
    local stderr, stdout = command_output.stderr, command_output.stdout
    if stderr ~= '' then
        notify.error("Received the following error while trying to start container " .. container_name .. ": " .. stderr)
        return false
    end
    if _is_container_running(container_name) == _docker_status.RUNNING then
        log.info("Successfully Started Container: " .. container_name)
        return true
    end
    notify.warn("Failed to start container: " .. container_name .. ' for reasons...?')
    return false
end
-- rest of file
```
The above follows a very similar pattern to our previous [is container alive](#docker-read-implementation) code we wrote so there isn't a need to rehash this.

Lastly we need to handle the event where the container _is_ running and we can interface with it (arguably the hardest part here).
Lets first consider if we are dealing with a file or directory? If we have a file, we should do 1 form of logic and if we have a directory we should do another form of logic. Especially as our directory will require us to verify that the container has
dependencies available for us!

##### Read File Implementation

Starting with file handling
[`docker.lua`](https://github.com/miversen33/netman.nvim/blob/e00a257c8c429c6c681c30907aa5cb23984cbc2e/lua/netman/providers/docker.lua)
```lua
-- docker.lua
-- rest of file
local _read_file = function(container, container_file, local_file)
    container_file = shell_escape(container_file)
    local command = 'docker cp -L ' .. container .. ':/' .. container_file .. ' ' .. local_file

    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''

    log.info("Running container copy file command: " .. command)
    local command_output = shell(command, command_options)
    log.debug("Container Copy Output " , {output=command_output})
    local stderr, stdout = command_output.stderr, command_output.stdout
    if stderr ~= '' then
        notify.error("Received the following error while trying to copy file from container: " .. stderr)
        return false
    end
    return true
end

function M:read(uri, cache)
-- rest of function
   else
        if cache.file_type == api_flags.ATTRIBUTES.FILE then
            if _read_file(cache.container, cache.path, cache.local_file) then
                return {
                    local_path = cache.local_file
                    ,origin_path = cache.path
                }, api_flags.READ_TYPE.FILE
                -- Return Details laid out in https://github.com/miversen33/netman.nvim/wiki/API-Documentation#readuri-cache
            else
                log.warn("Failed to read remote file " .. cache.path .. '!')
                notify.info("Failed to access remote file " .. cache.path .. " on container " .. cache.container)
                return nil
            end
        else
        -- We need to read the directory
        end
    end
end
-- rest of file
```
The big take away from the above code is this
- We are checking to see if we were able to pull the file down locally (as we are not streaming it across)
- We are returning useful errors in the event that we were not
- We are returning the appropriate return information as per the [API documentation](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#readuri-cache)

The rest of the code above follows similar patterns to what we have already seen and wont be further explained

So we have pulled down a file, lets check it and see what Netman does!
From a shell run the following command to get an [`ubuntu`]() container running and create a dummy file inside the `/tmp/` directory in it.
```shell
$ docker run -it ubuntu
root@4851725741a:/# echo "hello world" > /tmp/testing.txt
```
From a second shell, lets find the name of our temporary container
```shell
$ docker container ls
CONTAINER ID   IMAGE     COMMAND   CREATED         STATUS         PORTS     NAMES
4851725741a1   ubuntu    "bash"    4 minutes ago   Up 4 minutes             youthful_lederberg
```
We will want to notate the name `youthful_lederberg` (in this case, docker auto generates names if the name was not provided on start) as that is how we will access this container.
Lets open up `neovim` and try out our provider!
```
:luafile init.lua
:edit docker://youthful/lederberg///tmp/testing.txt
```

We will be presented with a buffer containing our `hello world` text, which is fantastic! We just read the contents of a file in a container into Neovim with Netman!

##### Read Directory Implementation

> Reading files into your buffer is great and all but what if you want to explore a directory? Who wants to put the absolute path of a file to edit anyway? Thats a lot of work!

You are correct! Lets look at how we would read a directory with [`Netman's Read`](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#readuri-cache) spec!

**WARNING: This is going to be a bit of dense code section, there is a lot of assumptions that you as the developer _know how to interface with the underlying protocol you are using_. Here, there are a lot of assumptions on `find` knowledge as well as `docker knowledge`. These things are _not_ covered here**

Using our above code snippet for the `read` function, lets add another bit of logic to deal with if the `file_type` is `api_flags.ATTRIBUTES.DIRECTORY`

```lua
-- docker.lua
-- rest of file
local _read_directory = function(cache, container, directory)
-- Process the read of a directory here
end

function M:read(uri, cache)
-- rest of function
   else
        if cache.file_type == api_flags.ATTRIBUTES.FILE then
        -- read file section described above
        else
            local directory_contents = _read_directory(cache, cache.container, cache.path)
            if not directory_contents then return nil end
            return directory_contents, api_flags.READ_TYPE.EXPLORE
            -- Should return details as laid out in https://github.com/miversen33/netman.nvim/wiki/API-Documentation#readuri-cache
        end
    end
end
-- rest of file
```

This stub code ensures that we will now have the ability to read both `files` in our docker container as well as `directories` in our container

From here, lets work through how we would implement a relatively simple `read_directory` function.

To read a directory we need the following items (at minimum)
- Directory Path
- Directory Contents
- Directory Contents Type (File (destination) or Directory (link)).
<!-- Explain Links vs Destination more-->

In our case, we have verified that the container we are interfacing with _has_ the required commands for us to introspect it (we will be using `find`), so we need to establish how to gather that information with `find`.  
**Note: As you work through interfacing with your protocol provider, be sure to take into account how you will handle your dependencies being unavailable!**

Below is the command we are going to use with `find` to gather the contents of a directory. This guide (and thus the below code) is not meant to be a template for how to read directory contents, and thus will not be explained. There are sections of the below code that are specific to how to interface with `Netman` and those will be commented as such to explain what they are doing. Things related to how we navigate throughout a docker container, reading the output of find, etc will be left up to you as the developer to work through.
[`docker.lua`](https://github.com/miversen33/netman.nvim/blob/3cead71b1ebcc284e687a3de71c1aa29414bc68e/lua/netman/providers/docker.lua)
```lua
-- docker.lua
local log = require("netman.utils").log
local notify = require("netman.utils").notify
local shell = require("netman.utils").run_shell_command
local shell_escape = require("netman.utils").escape_shell_command
local command_flags = require("netman.options").utils.command
local metadata_options = require("netman.options").explorer.METADATA

local find_command = [[find -L $PATH$ -nowarn -depth -maxdepth 1 -printf ',{\n,name=%f\n,fullname=%p\n,lastmod_sec=%T@\n,lastmod_ts=%Tc\n,inode=%i\n,type=%Y\n,symlink=%l\n,permissions=%m\n,size=%s\n,owner_user=%u\n,owner_group=%g\n,parent=%h/\n,}\n']]

local find_pattern_globs = {
    start_end_glob = '^,([{}])%s*'
    ,INODE = '^,inode=(.*)$'
    ,PERMISSIONS = '^,permissions=(.*)$'
    ,USER = '^,owner_user=(.*)$'
    ,GROUP = '^,owner_group=(.*)$'
    ,SIZE = '^,size=(.*)$'
    ,MOD_TIME = '^,lastmod_ts=(.*)$'
    ,FIELD_TYPE = '^,type=(.*)$'
    ,NAME = '^,name=(.*)$'
    ,PARENT = '^,parent=(.*)$'
    ,fullname = '^,fullname=(.*)$'
}
-- rest of file
local _process_find_results = function(container, results)
    local parsed_details = {} -- This is what will be (eventually) returned to `Netman`
    local partial_result = ''
    local details = {}
    local raw = ''
    local dun = false
    local size = 0
    local uri = 'docker://' .. container
    for _, result in ipairs(results) do
        dun = false
        if result:match(find_pattern_globs.start_end_glob) then
            dun = true
            goto continue
        end
        raw = raw .. result
        if result:sub(1,1) == ',' then
            partial_result = result
        else
            result = partial_result .. result
            partial_result = ''
        end
        for key, glob in pairs(find_pattern_globs) do
            local match = result:match(glob)
            if match then
                details[key] = match
                break
            end
        end
        ::continue::
        if dun and details.NAME then
            -- Here we are looping parsing the compiled output from 
            -- `find` to pick together the parts of it that we need
            -- to return to `Netman`.
            -- **NOTE: Names that are capitalized are pulled
            -- from Netman.options.explorer.METADATA and 
            -- must match what is in there in order to be
            -- passed to the explorer shim!**
            if details.FIELD_TYPE ~= 'N' then
                details.raw = raw
                details.PARENT = uri .. details.PARENT
                details.URI = uri .. details.fullname
                if details.FIELD_TYPE == 'd' then
                    details.FIELD_TYPE = metadata_options.LINK
                    details.NAME = details.NAME .. '/'
                    details.URI = details.URI .. '/'
                    -- Given how we as the provider handle
                    -- URI parsing, we are adding
                    -- a `/` to the end of the URI if the 
                    -- item we are inspecting is a directory.
                    -- This will ensure that our provider
                    -- will treat the child URI as a directory and
                    -- allow for further exploration of this directory
                else
                    details.FIELD_TYPE = metadata_options.DESTINATION
                end
                table.insert(parsed_details, details)
                size = size + 1
            end
            details = {}
            dun = false
            raw = ''
        end
    end
    parsed_details[size].URI = parsed_details[size].PARENT
    parsed_details[size].NAME = '../'
    -- We are setting the _parent_ of our directory name (what will be
    -- displayed by the explorer) to `../` as this is commonly
    -- what users understand to mean `go up a level`
    return {remote_files = parsed_details, parent = size}
    -- As prescribed in https://github.com/miversen33/netman.nvim/wiki/API-Documentation#readuri-cache this is returning the expected `table` for the explorer
end

local _read_directory = function(cache, container, directory)
    directory = shell_escape(directory)
    local command_output = {}
    local stderr, stdout = nil, nil
    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_OUTPUT_LINES] = true
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''
    if not cache.directory_command then
        log.debug("Generating Directory Traversal command")
        local commands = {
            {
                command = 'find --version'
                ,result_handler = {
                    command = find_command:gsub('%$PATH%$', directory)
                    ,result_parser = _process_find_results
                }
            },
        }
        for _, command_info in ipairs(commands) do
            log.debug("Running check command: " .. command_info.command)
            command_output = shell(command_info.command, command_options)
            stderr, stdout = command_output.stderr, command_output.stdout
            if stdout[2] == nil or stderr:match('command not found$') then
                log.info("Command: " .. command_info.command .. ' not found in container ' .. container)
            else
                cache.directory_command = command_info.result_handler.command
                cache.directory_parser = command_info.result_handler.result_parser
                goto continue
            end
        end
        log.warn("Unable to locate valid directory traversal command!")
        return nil
    end
    ::continue::
    command_output = {}
    stderr, stdout = nil, nil
    local command = 'docker exec ' .. container .. ' ' .. cache.directory_command
    log.debug("Getting directory " .. directory .. ' contents: ' .. command)
    command_output = shell(command, command_options)
    stderr, stdout = command_output.stderr, command_output.stdout
    if stderr and stderr ~= '' and not stderr:match('No such file or directory$') then
        notify.warn("Error trying to get contents of " .. directory)
        return nil
    end
    local directory_contents = cache.directory_parser(container, stdout)
    if not directory_contents then
        log.debug("Directory: " ..directory .. " returned an error of some kind in container " .. container)
        return nil
    end
    return directory_contents
end
-- rest of file
```

As stated earlier, the above codeblock is _mostly_ about how to interface with `find` and `docker`, and isn't going to be explained. There are however a few key points that deserve to be called out in the above section.

1) Be sure to fully review [The API spec on a provider's `read` implementation](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#readuri-cache)
    - In this it calls out exactly how the data for `read` should be returned for a directory. This is matched in the `_process_find_results` function above where we return a Table with the following 2 key-value pairs
        - `parent`: This is the Key associated with the `index` in the `details` array that is the parent element
        - `details`: This is a Table meeting the minimum listed key, value pairs required to be considered a valid `details` table.
2) Be sure to fully review [The API spec on what is valid for a provider to return in `details`]()
    - We return a variety of items that are associated with `Metadata` on each item in read. We do also return some things that _aren't_ associated with `Metadata`, and if you check the logs after opening a directory in the container, you will see `Netman` strips those items out. 
3) **`Netman` will strip _anything_ that is not allowed within the valid [`Metadata`]() for an item! This is to ensure a consistent set of data is always returned across providers. Ensure you adhere to this or you may have unexpected behavior in your displayed return results!**
4) Netman handles traversal of items in the directory via the explorer shim. That means you do not need to try to handle opening events on items or anything of the sort, just ensure that any items you want to handle via your provider have a properly formatted URI associated with them. Netman will direct any subsequent read commands for items back to the provider associated with the item's URI.
    - In practice this means that as long as we have each item in our return with a properly formatted `docker://` URI, Netman will ensure that any reads done within the return directory contents will be directed back to our provider to handle. Note: You _can_ mix URIs (meaning you _could_ format a URI to reach out to another provider if you feel that is needed).

Metadata options are detailed more in the [`API Spec`]()

The last thing we need to do with `read` is save our cache! Right now we are creating a new cache for every read and this is expensive and unnecessary! 

```lua
-- docker.lua
-- rest of file
function M:read(uri, cache)
    if next(cache) == nil then cache = _parse_uri(uri) end
    -- rest of function
-- rest of file
```

#### Implementing Write

Now that we can open files and directories, we need to support writing back to our container. Lucky for us, the hard part here is done!  
We will need to account for the following 2 actions here,
- Write a file (this includes updating an existing file)
- Create a directory

Netman will reach out to our provider's `write` function for both of these events. Let's stub out what this will look like!
```lua
-- docker.lua
-- rest of file
local _write_file = function(buffer_index, uri, cache)

end

local _create_directory = function(uri, cache)

end

function M:write(buffer_index, uri, cache)
    -- It is _not_ safe to assume we already
    -- have a cache so we should verify the
    -- cache we were given has contents
    if next(cache) == nil then cache = _parse_uri(uri) end
    if cache.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    local container_status = _is_container_running(cache.container)
    if container_status == _docker_status.ERROR then
        notify.error("Unable to find container! Check logs (:Nmlogs) for more details")
        return nil
    elseif container_status == _docker_status.NOT_RUNNING then
        log.debug("Getting input from user!")
        vim.ui.input({
            prompt = 'Container ' .. tostring(cache.container) .. ' is not running, would you like to start it? [y/N] ',
            default = 'Y'
        }
        , function(input)
            if input:match('^[yYeEsS]$') then
                local started_container = _start_container(cache.container)
                if started_container then require("netman"):read(uri) end
            elseif input:match('^[nNoO]$') then
                log.info("Not starting container " .. tostring(cache.container))
                return nil
            else
                notify.info("Invalid Input. Not starting container!")
                return nil
            end
        end)
    else
        if cache.type == api_flags.ATTRIBUTES.DIRECTORY then
            _create_directory(uri, cache)
        else
            _write_file(buffer_index, uri, cache)
        end
    end
end
-- rest of file
```

Notice that we stole a bunch of code from our `read` function? Lets break that into its own function and update `read` and `write` to use our new `_validate_container` function!

```lua
-- docker.lua
-- rest of file
local _validate_container = function(uri, container)
    local container_status = _is_container_running(container)
    if container_status == _docker_status.ERROR then
        notify.error("Unable to find container! Check logs (:Nmlogs) for more details")
        return nil
    elseif container_status == _docker_status.NOT_RUNNING then
        log.debug("Getting input from user!")
        vim.ui.input({
            prompt = 'Container ' .. tostring(container) .. ' is not running, would you like to start it? [y/N] ',
            default = 'Y'
        }
        , function(input)
            if input:match('^[yYeEsS]$') then
                local started_container = _start_container(container)
                if started_container then require("netman"):read(uri) end
            elseif input:match('^[nNoO]$') then
                log.info("Not starting container " .. tostring(container))
                return nil
            else
                notify.info("Invalid Input. Not starting container!")
                return nil
            end
        end)
    end
    return true
end
-- rest of file
function M:read(uri, cache)
    if next(cache) == nil then cache = _parse_uri(uri) end
    if cache.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
-- rest of function
-- rest of file
function M:write(buffer_index, uri, cache)
    -- It is _not_ safe to assume we already
    -- have a cache, additionally its possible
    -- that the uri provided doesn't match the
    -- cache uri so we should verify the cache
    -- we were given has contents
    if next(cache) == nil or cache.base_uri ~= uri then cache = _parse_uri(uri) end
    if cache.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    if not _validate_container(uri, cache.container) then return nil end
-- rest of function
-- rest of file
```
Awesome so now that that is done, lets continue with our `write` function!  
The next step is to write a file out so lets complete the `_write_file` function.

```lua
-- docker.lua
-- rest of file
local _write_file = function(buffer_index, uri, cache)
    vim.fn.writefile(vim.fn.getbufline(buffer_index, 1, '$'), cache.local_file)
    -- Get every line from the buffer from the first to the end and write it to the `local_file` 
    -- saved in our cache
    local local_file = shell_escape(cache.local_file)
    local container_file = shell_escape(cache.path)
    local command = 'docker cp ' .. local_file .. ' ' .. cache.container .. ':/' .. container_file
    log.debug("Saving buffer " .. buffer_index .. " to uri " .. uri .. " with command: " .. command)

    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = shell(command, command_options)
    if command_output.stderr ~= '' then
        log.warn("Received Error: " .. command_output.stderr)
        return false
    end
    return true
end
-- rest of file
```

Not a whole lot needs to be said about the above. One thing to note is that `Netman` does not provide the provider with the contents of the buffer. This is a purposeful decision as `Netman` should not make choices on how a provider gets whatever it is writing out to the protocol provider

Lets get `_create_directory` done next!
```lua
-- docker.lua
-- rest of file
local _create_directory = function(container, directory)
    local escaped_directory = shell_escape(directory)
    local command = 'docker exec ' .. container .. ' mkdir -p ' .. escaped_directory

    log.debug("Creating directory " .. directory .. ' in container ' .. container .. ' with command: ' .. command)
    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''
    local command_output = shell(command, command_options)
    if command_output.stderr ~= '' then
        log.warn("Received Error: " .. command_output.stderr)
        return false
    end
    return true
end
-- rest of file
```
As with above, there isn't much to talk about here so lets get both of these plugged into `write`.
[`docker.lua`](https://github.com/miversen33/netman.nvim/blob/808df0e7b22bfa2eee811287b8757ff02d909789/lua/netman/providers/docker.lua)
```lua
-- docker.lua
-- rest of file
function M:write(buffer_index, uri, cache)
    -- It is _not_ safe to assume we already
    -- have a cache, additionally its possible
    -- that the uri provided doesn't match the
    -- cache uri so we should verify the cache
    -- we were given has contents
    if next(cache) == nil or cache.base_uri ~= uri then cache = _parse_uri(uri) end
    if cache.protocol ~= M.protocol_patterns[1] then
        log.warn("Invalid URI: " .. uri .. " provided!")
        return nil
    end
    if not _validate_container(uri, cache.container) then return nil end
    local success = false
    if cache.file_type == api_flags.ATTRIBUTES.DIRECTORY then
        success = _create_directory(cache.container, cache.path)
    else
        success = _write_file(buffer_index, uri, cache)
    end
    if not success then
        notify.error("Unable to write " .. uri .. "! See logs (:Nmlogs) for more details!")
    end
end
-- rest of file
```
It is worth noting that we are informing the user in the event of a failed write.  
Its also valuable to consider, the [`API Documentation`](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#writebuffer_index-uri-cache) calls out that `write` should be able to perform asynchronously.

#### Implementing Delete

Delete will actually follow _effectively_ the same logic as `write`, however since `Deleting` is so simple, this section will be very brief. Below is a quick docker implementation of what `delete` would look like
[`docker.lua`](https://github.com/miversen33/netman.nvim/blob/2c0622a19ddf87a6dddce38ab18cb9245cb2c69e/lua/netman/providers/docker.lua)
```lua
-- docker.lua
-- rest of file
function M:delete(uri)
    -- It is _not_ safe to assume we already
    -- have a cache, additionally its possible
    -- that the uri provided doesn't match the
    -- cache uri so we should verify the cache
    -- we were given has contents
    local cache = _parse_uri(uri)
    local path = shell_escape(cache.path)
    local command = 'docker exec ' .. cache.container .. ' rm -rf ' .. path

    local command_options = {}
    command_options[command_flags.IGNORE_WHITESPACE_ERROR_LINES] = true
    command_options[command_flags.STDERR_JOIN] = ''

    vim.ui.input({
        prompt = 'Are you sure you wish to delete ' .. cache.path .. ' in container ' .. cache.container .. '? [y/N] ',
        default = 'N'
    }
    , function(input)
        if input:match('^[yYeEsS]$') then
            log.debug("Deleting URI: " .. uri .. ' with command: ' .. command)
            local command_output = shell(command, command_options)
            local success = true
            if command_output.stderr ~= '' then
                log.warn("Received Error: " .. command_output.stderr)
            end
            if success then
                notify.warn("Successfully Deleted " .. cache.path .. ' from container ' .. cache.container)
            else
                notify.warn("Failed to delete " .. cache.path .. ' from container ' .. cache.container .. '! See logs (:Nmlogs) for more details')
            end
        elseif input:match('^[nNoO]$') then
            notify.warn("Delete Request Cancelled")
        end
    end)
end
-- rest of file
```
A few key points about `delete`
1) [Delete is not provided the cache](https://github.com/miversen33/netman.nvim/wiki/API-Documentation#deleteuri)
    - This is because the location that the user may be requesting to have deleted may not have a cache associated with it within Netman. Netman only gets its cache object from the providers `read` function, and that function may not have been called on the URI that deletion has been requested for.
2) Confirm your deletion before doing it
    - This is not necessarily standard and more just helping protect a user from themselves. Accidental deletions calls may happen from time to time and it is worth making the process of deleting a file/directory a bit harder (in this case, requiring confirmation). 

### How to troubleshoot your shiny new provider
- Common Troubleshooting Steps will be listed here

As you begin working through development of your provider, it is wise to use a [`clean`]() configuration so as to avoid conflicts with other plugins (until you are sure your provider is stable). Additionally, it is wise to commonly refer to `:Nmlogs` as this will provide a quick glance into what Netman is seeing from your provider as well as what it is doing to handle interfacing with your provider.