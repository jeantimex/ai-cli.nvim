# ai-cli.nvim

Neovim integration for coding CLIs.

`ai-cli.nvim` keeps a coding CLI available inside Neovim as a persistent side terminal and opens code suggestions in a reviewable unified diff inside your editor windows.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "jeantimex/ai-cli.nvim",
  config = function()
    require("ai-cli").setup()
  end,
}
```

If you use `lazy.nvim` lazy-loading and want `:AiCli` commands to work before any keymap is pressed, load the plugin with one of these approaches:
- `event = "VeryLazy"` (recommended)
- `cmd = { "AiCli", "AiCliOpen", "AiCliClose", ... }`
- `lazy = false`

## Configuration

Default configuration:

```lua
require("ai-cli").setup({
  provider = "gemini",
  auto_start = true,
  terminal_cmd = "gemini",
  env = {},
  log_level = "info",
  terminal = {
    split_side = "right",
    split_width_percentage = 0.4,
    auto_close = true,
  },
  diff = {
    accept_key = "ga",
    reject_key = "gr",
  },
})
```

The core plugin always sets these general Neovim integration variables:
- `NVIM`: Neovim server name
- `EDITOR`: `nvim`

Provider-specific setup lives behind provider modules:

```text
lua/ai-cli/providers/
  init.lua
  gemini.lua
```

## Features

- Persistent terminal split inside Neovim.
- Native `vsplit` behavior, including mouse drag-resize.
- Terminal session stays alive when you hide and reopen the side pane.
- Terminal buffer is treated like a utility pane (`buflisted = false`, custom filetype).
- Local bridge so the active CLI can open and resolve code suggestions directly in Neovim.
- Unified diff review flow with editor-side accept/reject keymaps.
- Deferred diff opening for files that are not currently visible.
- Automatic buffer refresh when the CLI or external commands modify files on disk.
- Editor-side acceptance and CLI-side approval flows both keep Neovim and the CLI in sync.

## Code Suggestions

When the active provider proposes an edit, the plugin opens a dedicated diff review in a temporary buffer.

- `ga` accepts the suggestion, writes it to disk, and updates any open buffers.
- `gr` rejects the suggestion.
- `q` closes the review and rejects it.
- If the target file is not currently visible in Neovim, the suggestion is queued and automatically opens when you visit that file.
- Opening the diff does not have to steal focus from the terminal pane.
- If a suggested change is applied externally from the terminal pane, the diff view is resolved automatically.

The plugin also enables `autoread`, so files modified on disk by the CLI are automatically reloaded in Neovim.

## Commands

The current command surface is shared plugin behavior:

- `:AiCli [args]` toggles the terminal window
- `:AiCliOpen [args]` opens the terminal window
- `:AiCliClose` closes the terminal window
- `:AiCliWidth 45` sets the split width to a percentage of the editor width
- `:AiCliWider` increases the split width
- `:AiCliNarrower` decreases the split width
- `:AiCliAdd` prints the `/add` helper for the current file
- `:AiCliRefresh` manually reloads the current buffer from disk

## Minimum Setup

Smallest working setup for the bundled Gemini provider:

```lua
{
  "jeantimex/ai-cli.nvim",
  event = "VeryLazy",
  config = function()
    require("ai-cli").setup({
      provider = "gemini",
      terminal_cmd = "gemini",
    })
  end,
}
```

## Gemini CLI Setup

The bundled provider today is Gemini.

Use this when you want to configure Gemini explicitly:

```lua
require("ai-cli").setup({
  provider = "gemini",
  terminal_cmd = "gemini",
  env = {},
  terminal = {
    split_side = "right",
    split_width_percentage = 0.4,
    auto_close = true,
  },
  diff = {
    accept_key = "ga",
    reject_key = "gr",
  },
})
```

The Gemini provider injects these extra environment variables:
- `GEMINI_CLI_IDE_SERVER_PORT`
- `GEMINI_CLI_IDE_PID`
- `GEMINI_CLI_SYSTEM_DEFAULTS_PATH`

It also writes a temporary Gemini system-defaults file so Gemini can discover the Neovim bridge in IDE mode.

Minimal Gemini `lazy.nvim` setup for developers:

```lua
{
  "jeantimex/ai-cli.nvim",
  event = "VeryLazy",
  config = function()
    require("ai-cli").setup({
      provider = "gemini",
      terminal_cmd = "gemini",
    })
  end,
}
```

## Workflow Notes

- The terminal pane is pinned to its own split and should stay separate from normal code windows.
- Clicking buffer tabs while focus is inside the terminal should switch files in the code area, not replace the terminal buffer.
- If the active provider suggests a change for a file you are not currently viewing, open that file and the unified diff should appear there.
- You can review changes either from the editor with `ga` / `gr` or from the CLI with the built-in approval action.
- Since the terminal window is a real split, manual mouse resizing works naturally.

## Extending To Other CLIs

The codebase is split into provider-agnostic editor modules and provider-specific adapters.

Provider-agnostic pieces:
- `lua/ai-cli/terminal.lua` manages the pinned terminal split
- `lua/ai-cli/diff.lua` owns the unified diff UI and pending diff queue
- `lua/ai-cli/server.lua` owns the local bridge transport
- `lua/ai-cli/init.lua` wires the active provider into the shared UI and sync flow

Provider-specific pieces:
- `lua/ai-cli/providers/init.lua` resolves the active provider
- `lua/ai-cli/providers/gemini.lua` defines Gemini-specific command and environment behavior

Each provider module should own:
- how to build the CLI command
- which environment variables to inject
- any provider-specific defaults files
- request/response normalization for tool calls

To add a new CLI later, the intended path is:

1. add a new provider file such as `lua/ai-cli/providers/claude.lua`
2. expose it from the provider registry
3. implement the same responsibilities as the Gemini provider
4. select it with `provider = "claude"` in `setup()`

That keeps the terminal UX, diff UX, and refresh behavior shared across providers while allowing each CLI to define its own launch contract and bridge semantics.

## License

MIT
