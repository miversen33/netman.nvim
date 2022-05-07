# Neovim (Lua Powered) Network Resource Manager

[Interested in how Netman Works or how to integrate with it?](https://github.com/miversen33/netman.nvim/wiki)

## WIP

# Table of Contents
- [TLDR](#tldr)
- [Goals](#goals)
- [Dependencies](#dependencies)
- [Installation](#installation)
- [Usage](#usage)
    - [:NmloadProvider](#nmloadprovider)
    - [:Nmlogs](#nmlogs)
    - [:Nmread](#nmread)
    - [:Nmdelete](#nmdelete)
    - [:Nmwrite](#nmwrite)
    - [Supported Network Protocols](#currently-supported-network-protocols)
        - [SSH](#ssh)
        - [Docker](#docker)
    - [Targeted Network Protocols](#targeted-network-protocols)
- [Debugging](#debugging)

## TLDR
> What am I?

Netman is a framework that plugins can utilize to expose remote resources (such as ssh filesystems, docker containers, database tables, etc) to the user via a standard API.

> Why would I use this instead of `X` plugin?

Netman's aim is to sit _under_ `X` plugin and provide an easier experience for both `X` plugin and other plugins to expose their remote resources to a user

> Isn't [Netrw](http://www.drchip.org/astronaut/vim/index.html#NETRW) included in Neovim? Why would I use [Netman](https://github.com/miversen33/netman.nvim)?

It is! The goal of Netman is to free Neovim from having to use Netrw for remote resource accessing as Netrw is a slower, more antiquated, and non-extensible means of remote resource interaction.
## Goals
Netman aims to sit between Neovim, the end user and remote resources. In practical terms, this means that Netman's goal is to provide a framework for other plugins to utilize, to interface seamlessly with remote resources via Netman's [provider](https://github.com/miversen33/netman.nvim/wiki) system. Netman additionally comes with a handful of providers in its core which are documented in the [Currently Supported Network Protocols](#currently-supported-network-protocols) section of this doc.

Netman does _not_ aim to implement providers for every protocol in existence, rather to establish a framework for **others** to provide that support.

This goal will allow Neovim to support an arbitrary set of protocols for editing as opposed to being locked against whatever the current version of Netrw supports.

## Dependencies

There are 2 pieces to Netman, the API (documented [here]()) and its Providers.
The API does not have any external dependencies (with the exception of Unit Testing).
The providers however may have dependencies which are uncontrollable from Netman's perspective. This is due to a provider needing to interface with arbitrary programs on local and remote machines in order to meet Netman's API requirements. 

Within Netman core, there are 2 implemented providers
- SSH
- Docker

These have the following requirements
- SSH
    - Local Machine needs [`ssh`]() as well as [`sftp`]()
    - Remote Machine needs [`ssh`](), [`sftp`](), [`find`](), [`rm`]()
- Docker
    - Local Machine needs [`docker`]()
    - Container needs [`find`](), [`rm`]()

Failing to have a required dependency for a provider will _not_ prevent Netman from offering its functionality, however it will prevent the provider who's requirements are not met from running.

In other words, if you do not have `docker` installed, you can not use the docker provider (for example).

## Installation
Installing Netman is done the same as any other package. As it has no external dependencies it requires to be used/installed, it does not need much. 
Consult your preferred package manager for how to install packages

## Usage
Using Netman is easy! Simply add the following line somewhere to your `init.lua` file
```lua
require("netman")
```

Once Netman is loaded into memory, it will automatically load its providers. If you are using 3rd party providers, they will have already loaded themselves into memory and thus you wont need to load them into Netman.

From here, simply use Neovim as you would usually. However you will now have the ability to interact with Remote Resources (remote files, remote directories, remote streams, etc) through Netman and any associated providers you have. Examples of this would be to open a file/directory via the `ssh` provider.

Simply open the file as you would any other file
```
:edit sftp://myhost/myfile.txt
```
You can also do it directly from your cli
```sh
nvim sftp://myhost/myfile.txt
```
Netman is smart enough to prevent `Netrw` from consuming this event and will instead pass it off to the core `ssh` provider.

Additionally Netman exposes the following Vim commands should you choose to use them
```
:NmloadProvider
:Nmlogs
:Nmdelete
:Nmread
:Nmwrite
```

Vim help doc is pending, but each of these is described below
### :NmloadProvider
Takes 1 argument (the path to a provider to load) and calls `Netman.api:load_provider`. This will mostly be used by developers expirimenting with provider creation/configuration.
Example:
```
:NmloadProvider netman.providers.docker
```
Can also be called via lua
```
:lua require("netman.api"):load_provider("netman.providers.docker")
```

### :Nmlogs
Takes either 0 or 1 argument, where the argument is the location to dump the session logs.
This will filter through the Netman logs to pull only logs related to the current Neovim session and store it in the location provided, and then format the logs and display them in a buffer
**Note: If no argument is provided, Nmlogs will generate a file in your home directory and store the logs in that**
**Note: If the argument provided is `memory`, Nmlogs will _not_ dump a file out and will simply render the logs to a buffer.**
Example:
```
:Nmlogs
OR
:Nmlogs my_log_file
OR
:Nmlogs memory
```
Can also be called via lua
```
:lua require("netman.api):dump_info()
OR
:lua require("netman.api):dump_info("my_log_file")
OR
:lua require("netman.api):dump_info("memory")
```

### :Nmdelete
Takes exactly 1 argument, the URI to delete. This will call out to Netman's delete function to delete the URI resource
Example:
```
:Nmdelete sftp://myhost/mydir/myfile.txt
```
Can also be called via lua
```
:lua require("netman"):delete("sftp://myhost/mydir/myfile.txt")
```

### :Nmread
Takes `n` arguments (where `n` > 0) and opens each in a new buffer. 
Example:
```
:Nmread sftp://myhost/mydir/
OR
:Nmread docker://mycontainer/mydir/myfile.txt
```
Can also be called via lua
```
:lua require("netman"):read("sftp://myhost/mydir/)
OR
:lua require("netman"):read("docker://mycontainer/mydir/myfile.txt")
```

### :Nmwrite
Takes 0 arguments, this will write the current buffer out to its associated provider
Example:
```
:Nmwrite
```
Can also be called via lua
```
:lua require("netman"):write()
```

### Currently Supported Network Protocols
#### SSH
Accessing files/directories over ssh can be done in below URI format
- $PROTOCOL://[$USERNAME@]$HOSTNAME[:$PORT]/[//][$PATH]
    A break down of what is happening here
    - `$PROTOCOL`: Must be either `sftp`, `scp`, or `ssh`
    - `$USERNAME`: The username to authenticate with (Optional)
    - `$HOSTNAME`: The hostname to connect to. Supports using hostnames defined in an [SSH CONFIG](https://linux.die.net/man/5/ssh_config) file
    - `$PORT`    : The port to connect to (Optional)
    - `/[//]`    : Forward slash (one) is considered a relative path to the `$USER` home directory. Note, this will work regardless of if `$USER` is specified or not. Providing `///` will act as a "Full Path" override
    - `$PATH`    : The path to a file/directory to interact with. If not provided, defaults to `/[//]` as described above (Optional)

Current Limitations:
- Interactive authentication currently do not work
    If you need a password or keyphrase to enter a box, currently this will just fail (ish?).
    - This is being investigated in [issue 33](https://github.com/miversen33/netman.nvim/issues/33)

Example:
```
:edit sftp://myuser@myhost:myport///my/absolute/path/file.txt
OR
:edit sftp://myhost/my/relative/path/file.txt
OR
:Nmread scp://myhost/myfile.txt
OR
:lua require("netman"):read("ssh://myhost/mydir/file.txt")
```

#### Docker
Accessing files/directories in a container can be done in the URI below format
- $PROTOCOL://$CONTAINER/$PATH
    A break down of what is happening here
    - `$PROTOCOL` : Must be either `sftp`, `scp`, or `ssh`
    - `$CONTAINER`: The container (by name) to open
    - `$PATH`     : The path to a file/directory to interact with.
    **NOTE: Unlike the `ssh` provider, the `docker` provider does _not_ allow relative pathing

Current Limitations:
- Does not respect container by ID
    - Maybe addressed in the future if users care?

Example:
```
:edit docker://mycontainer/my/dir/to/file.txt
OR
:Nmread docker://mycontainer/my/dir/to/file.txt
OR
:lua require("netman"):read("docker://mycontainer/my/dir/to/file.txt")
```

### Targeted Network Protocols
- [ ] Rsync

## Debugging

When debugging your netman session, ensure that you are running in `DEBUG` mode. This can be done by simply setting
```lua
vim.g.netman_log_level = 1
```
in your `init.lua` configuration file.
**NOTE: It is recommended that you place this line somewhere before you import plugins as `Netman` automatically sets itself up on import of itself or `api`. Any logging during initialization is lost if the appropriate level is not set before that**

Valid log levels are
- 4 (Error)
- 3 (Warn)
- 2 (Info)
- 1 (Debug)
- 0 (Trace)
These are in conjunction with [vim.log.levels](https://neovim.io/doc/user/lua.html#vim.log.levels)


**NOTE: Debug mode a significantly volume of logs, ensure you only have it on when its needed**

When you encounter a bug that you wish to submit an issue for, 
please refer to [How to fill out issue](https://github.com/miversen33/netman.nvim/issues/3). Netman is designed to make
your life as the user easy. To help accomplish this, netman has a command built in
specifically to dump session logs for you.
[:Nmlogs](#nmlogs)

This will dump the session log out into the above listed `/home/miversen33/WHY_YOU_BIG_DED.log` file, which can then be retrieved and uploaded with your issue. Additionally, the generated log will be opened up in a new `NetmanLogs` filetype buffer, formatted and available for viewing. This should prove
helpful for developers as they work through integration with Netman.

NOTE: In order for the logs to be useful, it is required that `:Nmlogs` be ran from within the problem session as only the logs associated with the current session will be aggregated.

The Netman logfile for netman is stored in `$HOME/.local/nvim/netman/logs.txt` if you would prefer to look through this in an attempt to troubleshoot issues

**NOTE: This does _not_ scrub sensitive content, so it is wise to ensure there are no passwords or the like in this log before uploading it**