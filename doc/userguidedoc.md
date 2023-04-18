<sup>[Source can be found here](https://github.com/miversen33/netman.nvim/blob/main/doc/userguidedoc.md)</sup>  
Are you a new user of Netman just trying to "make the thing work!"?

If so, you've come to the right place! Below is a simple, no-frills step-by-step guide to get Netman working on your system.

# Getting Started
[Installation](#installation)  
[Setup](#setup)  
[Gotchas](#gotchas)

## Installation
### Packer
```lua
-- Add this to your packer plugin setup section
use 'miversen33/netman.nvim'
-- Add the require somewhere after your plugins have been added by packer. Note,
-- you do not need this if you plan on using Netman with any of the
-- supported UI Tools such as Neo-tree
require "netman"
```
### Vim Plug
```vim
" Add this near the top of your vim plug configuration
Plug 'miversen33/netman.nvim'
" Note, you do not need this if you plan on using Netman with any of the
" supported UI Tools such as Neo-tree
lua require "netman"
```
### Lazy
```lua
-- Add this to your Lazy plugin setup section
{
    'miversen33/netman.nvim',
    -- Note, you do not need this if you plan on using Netman with any of the
    -- supported UI Tools such as Neo-tree
    config = true
}
```

## Setup
Open Neovim and either use a UI tool that supports Netman (such as Neo-tree) or the in built vim commands to navigate your remote system
- Supported UI Tools
    - [Neo-Tree](#neo-tree)
- [`:Nmread`](https://github.com/miversen33/netman.nvim#nmread)
- [`:Nmwrite`](https://github.com/miversen33/netman.nvim#nmwrite)
- [`:Nmdelete`](https://github.com/miversen33/netman.nvim#nmdelete)  

### Neo-tree
Netman has native support for the [Neo-tree](https://github.com/nvim-neo-tree/neo-tree.nvim/) tree browser.
[Take a peek at the current issues with this integration before submitting a new issue, your problem might be tracked already](https://github.com/miversen33/netman.nvim/labels/Neo-tree)

Below is how to add Netman to Neo-tree
```lua
require("neo-tree").setup({
    sources = {
        -- Any other Neo-tree sources you had/want.
        -- Just add the netman source somewhere in this array
        "netman.ui.neo-tree", -- The one you really care about 😉
    },
    -- If you want Netman to appear in the winbar/statusline, you will need
    -- to setup source selector
    source_selector = {
        sources = {
            -- Any other items you had in your source selector
            -- Just add the netman source as well
            { source = "remote" }
        }
    }
})
```
The above will get you something that looks like this  
![image](https://user-images.githubusercontent.com/2640668/232776760-463238a8-1ee6-44fe-bdbd-9a986babde3d.png)

From here, you can enter the "Provider" node (either by double clicking or pressing enter on it) to see your active providers  
![image](https://user-images.githubusercontent.com/2640668/232776898-c490188f-5e6b-43d5-9bee-393b839583a4.png)

Selecting a provider will reveal its hosts  
![image](https://user-images.githubusercontent.com/2640668/232776999-1845a0f5-37d9-4c2a-9230-85b662df239d.png)

And selecting a host will reveal its remote system  
![image](https://user-images.githubusercontent.com/2640668/232777086-3060229f-3319-4814-9ddc-4c8d965a6023.png)

This guide will **not** explain all the details on how to use Neo-tree, feel free to head over the the [neo-tree repository](https://github.com/nvim-neo-tree/neo-tree.nvim) for
those details.  
**NOTE: If you are unsure what to do when you have the Neo-tree window open, you can press the `?` button and it will display a list of available commands for you.**

## Gotchas
Netman auto populates its providers, and the providers auto populate what they can read. This means that any providers installed will "automagically" work if they can. If they work, they will "automagically" provide access to your remote systems.  
Out of the box, Netman comes with `ssh` and `docker` providers. You can quickly check what providers are available by running the `:Nmlogs` command. This outputs (among the system logs) a section at the top of the buffer that states the active providers, as well as reasons for any inactive providers.

Here is what you will see (roughly) with `:Nmlogs`. Note, if you are submitting an issue, please provide the full output of `:Nmlogs`  
![image](https://user-images.githubusercontent.com/2640668/232781757-45ab8386-cd1f-4f10-8bfa-261b78b9e28b.png)


### SSH Provider
The SSH provider will read your [user's ssh configuration](https://linux.die.net/man/5/ssh_config) to establish what hosts it can connect to.  
**This is only important if you wish to use a UI tool (such as [Neo-tree](#neo-tree)). It does not have an impact on the various vim commands.**  
If you want more hosts to appear under the `SSH` provider, you will need to ensure you have valid entries in your SSH configuration and refresh the provider. Refer to the UI tool of choice for details on how to refresh.

### Docker Provider
The docker provider will talk to the system's docker cli (See [#65](https://github.com/miversen33/netman.nvim/issues/65) for tracking of migration to using docker socket) to establish what containers are on the system.  
**This is only important if you wish to use a UI tool (such as [Neo-tree](#neo-tree)). It does not have an impact on the various vim commands.**  
If you want more hosts to appear under the `Docker` provider, you will need to start a new container and refresh the provider. Refer to the UI tool of choice for details on how to perform a refresh.

