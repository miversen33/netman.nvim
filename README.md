# Neovim (Lua Powered) Network File Manager

## WIP

## Goals

Netman's target is to provide a wholely lua written replacement for [Netrw](http://www.drchip.org/astronaut/vim/index.html#NETRW) that acts as a "drop in" replacement for how one would interact with Netrw.

- [ ] Remote File Management
- [ ] Local File Management
- [ ] Fully Functional with Neovim LSP

## Dependencies

Your client (and server) will need whatever software is necessary to use the remote protocol of your chosing. This means that if you wish to connect to a remote file system via sftp/scp, your client and server must both have installed (and running) ssh. 
The server must have [find](https://man7.org/linux/man-pages/man1/find.1.html) installed (this is usually preinstalled on most linux environments)

- SSH (For file system management via sftp/scp)
- find

## Usage

Using Netman should be as simple as adding this line to your `init.lua`

```lua
require('netman.nvim').setup({})
```

The definition for the table in `setup` is as follows (**NOT IMPLEMENTED YET!**)
```lua
{
    allow_netrw = false, 
        -- By default, Netman will remove Netrw and act in its place. 
        -- You can set this flag to `true` to allow Netman to operate 
        -- behind Netrw. This is especially useful if you plan on 
        -- using Netman as a "provider" for other services, as opposed
        -- to using Netman as a standin for Netrw
    keymaps = {},
        -- PENDING IMPLEMENTATION
    debug   = false,
        -- Passing this as true will enable significant more log output.
        -- Note: Logs are output by default to `$HOME/.cache/nvim/netman/logs.txt`
        -- though this is likely to change to a better (more fitting) location.
    providers = {
        "netman.providers.ssh"
        -- List of providers to utilize for remote filesystem interfacing
    },
}
```

## Network Protocols Targeted
- [ ] [SSH](#ssh) **CURRENT TARGET FOR IMPLEMENTATION**
- [ ] Rsync
- [ ] FTP
- [ ] Webdav

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

