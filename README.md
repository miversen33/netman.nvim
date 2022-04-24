# Neovim (Lua Powered) Network File Manager

## WIP

## Goals

While netman was originally targetted at replacing [Netrw](http://www.drchip.org/astronaut/vim/index.html#NETRW) with a lua drop in, it has grown to different aspirations. Below is the current list of goals for Netman

- [ ] Remote File Management
- [ ] Extensible Framework to Integrate Remote Filesystems with Existing File Managers
- [ ] [Fully Functional with Neovim LSP](#lsp)

## Dependencies

Your client (and server) will need whatever software is necessary to use the remote protocol of your chosing. This means that if you wish to connect to a remote file system via sftp/scp, your client and server must both have installed (and running) ssh. 
The server must have [find](https://man7.org/linux/man-pages/man1/find.1.html) installed (this is usually preinstalled on most linux environments)

- find
- [Required Protocols for Remote Providers](#core-providers)

## Usage

Using Netman should be as simple as adding this line to your `init.lua`

```lua
require('netman')
```

You can customize netman for yourself via the `:config` method
```lua 
require('netman'):config({})
```
<!-- TODO: Update this -->
The definition for the table in `config` is as follows (**NOT IMPLEMENTED YET!**)
```lua
{
    keymaps = {},
        -- PENDING IMPLEMENTATION
    debug   = false,
        -- Passing this as true will enable significant more log output.
        -- Note: Logs are output by default to `$HOME/.local/nvim/netman/logs.txt`
        -- though this is likely to change to a better (more fitting) location.
    compress = false,
        -- Setting "compress" to true will prompt the underlying provider to also
        -- compress traffic as it pulls it across the network. By defualt
        -- this is turned off to better compensate for speed lost due
        -- to compressing files, however it can be enabled if you are 
        -- experiencing long delays in getting files across the network (usually
        -- related to slow/underpowered networks)
    providers = {
        "netman.providers.ssh"
        -- List of providers to utilize for remote filesystem interfacing
    },
}
```

## Network Protocols Targeted
- [x] [SSH](#ssh) **CURRENT TARGET FOR IMPLEMENTATION**
- [ ] Rsync
- [ ] Docker

## Core Providers

### SSH

Accessing files/directories over ssh can be done in below format
- $PROTOCOL://[$USERNAME@]$HOSTNAME[:$PORT]/[//][$PATH]
  
    A break down of what is happening here
    - `$PROTOCOL`: Must be either `sftp` or `scp`
    - `$USERNAME`: The username to authenticate with (Optional)
    - `$HOSTNAME`: The hostname to connect to. Supports using hostnames defined in an [SSH CONFIG](https://linux.die.net/man/5/ssh_config) file
    - `$PORT`    : The port to connect to (Optional)
    - `/[//]`    : Forward slash (one) is considered a relative path to the `$USER` home directory. Note, this will work regardless of if `$USER` is specified or not. Providing `///` will act as a "Full Path" override
    - `$PATH`    : The path to a file/directory to interact with. If not provided, defaults to `/[//]` as described above (Optional)

Current Limitations:
- Interactive authentication currently do not work
    If you need a password or keyphrase to enter a box, currently this will just fail (ish?).
    - This is being investigated in [issue 33](https://github.com/miversen33/netman.nvim/issues/33)

## Debugging

When debugging your netman session, ensure that you have netman running in `DEBUG` mode. To do this, update your `setup` configuration to include `debug=true` in the input table. An example
```lua
require('netman'):init({'debug'=true})
```

By using the debug flag, significantly more information is output into the logs.
When you encounter a bug that you wish to submit an issue for, 
please refer to [How to fill out issue](https://github.com/miversen33/netman.nvim/issues/3). Netman is designed to make
your life as the user easy. To help accomplish this, netman has a command built in
specifically to dump session logs for you.
```vim
:Nmlogs
```
-- More details coming on how its implemented and how to use it.

You can additionally provide an output path for the logs to be stored at
```vim
:Nmlogs /home/miversen33/WHY_YOU_BIG_DED.log
```
This will dump the session log out into the above listed `/home/miversen33/WHY_YOU_BIG_DED.log` file, which can then be retrieved and uploaded with your issue.

NOTE: In order for the logs to be useful, it is required that `:Nmlogs` be ran from within
the problem session as only the logs associated with the current session will be aggregated.

The logfile for netman is stored in `$HOME/.local/nvim/netman/logs.txt` if you would prefer to 
look through this in an attempt to troubleshoot issues

**NOTE: This does _not_ scrub sensitive content, so it is wise to ensure there are no passwords or the like in this log before uploading it**