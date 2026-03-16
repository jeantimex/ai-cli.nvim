# ai-cli.nvim

Neovim integration for coding CLIs, starting with Gemini CLI.

This plugin keeps an AI coding CLI available inside Neovim as a persistent side terminal and opens code suggestions in a reviewable unified diff inside your editor windows.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "jeantimex/ai-cli.nvim",
  config = function()
    require("ai-cli").setup({
      -- your configuration
    })
  end,
}
```

## Configuration

Default configuration:

```lua
require("ai-cli").setup({
  provider = "gemini", -- current provider adapter
  auto_start = true, -- start the bridge server automatically
  terminal_cmd = "gemini", -- command to start the active CLI
  env = {}, -- extra environment variables
  log_level = "info",
  terminal = {
    split_side = "right", -- open Gemini on the "left" or "right"
    split_width_percentage = 0.4, -- initial Gemini split width
    auto_close = true, -- close terminal window when process exits
  },
  diff = {
    accept_key = "ga", -- accept a Gemini code suggestion
    reject_key = "gr", -- reject a Gemini code suggestion
  },
})
```

The plugin automatically sets several environment variables for the active CLI. Today the bundled Gemini provider injects:
- `GEMINI_CLI_IDE_SERVER_PORT`: Port for the Neovim bridge server.
- `GEMINI_CLI_IDE_PID`: PID of the Neovim process.
- `NVIM`: Neovim server name.
- `EDITOR`: Set to `nvim`.

Internally, provider-specific setup lives behind a provider module:

```text
lua/ai-cli/providers/
  init.lua
  gemini.lua
```

## Features

- Persistent AI terminal split inside Neovim.
- Native `vsplit` behavior, including mouse drag-resize.
- Terminal session stays alive when you hide and reopen the side pane.
- The terminal buffer is treated like a utility pane (`buflisted = false`, custom filetype).
- Local bridge so the active CLI can open and resolve code suggestions directly in Neovim.
- Unified diff review flow with editor-side accept/reject keymaps.
- Deferred diff opening for files that are not currently visible.
- Automatic buffer refresh when the CLI or external commands modify files on disk.
- Editor-side acceptance and CLI-side "Allow" flows both keep Neovim and the CLI in sync.

## Code Suggestions

When the active provider proposes an edit, the plugin opens a dedicated diff review in a temporary buffer.

- `ga` (default) accepts the suggestion, writes it to disk, and updates any open buffers.
- `gr` (default) rejects the suggestion.
- `q` closes the review and rejects it.
- If the provider edits a file that is not currently visible in Neovim, the suggestion is queued and automatically opens when you visit that file.
- Opening the diff does not have to steal focus from the terminal pane; you can stay in the CLI and press Enter on "Allow".
- If a suggested change is applied externally from the terminal pane, the diff view is resolved automatically.

The plugin also enables `autoread`, so files modified on disk by the CLI are automatically reloaded in Neovim.

## Commands

- `:Gemini [args]` - Toggle the Gemini terminal window.
- `:GeminiOpen [args]` - Open the Gemini terminal window.
- `:GeminiClose` - Close the Gemini terminal window.
- `:GeminiWidth 45` - Set Gemini split width to a percentage of the editor width.
- `:GeminiWider` - Increase Gemini split width.
- `:GeminiNarrower` - Decrease Gemini split width.
- `:GeminiAdd` - Helper to add the current file to Gemini's context (prints the `/add` command).
- `:GeminiRefresh` - Manually reload the current buffer from disk.

## Suggested Keymaps

Example `lazy.nvim` config:

```lua
{
  "jeantimex/ai-cli.nvim",
  config = function()
    require("ai-cli").setup()
  end,
  keys = {
    { "<leader>gg", "<cmd>Gemini<cr>", desc = "Toggle Gemini", mode = "n" },
    { "<leader>go", "<cmd>GeminiOpen<cr>", desc = "Open Gemini", mode = "n" },
    { "<leader>gc", "<cmd>GeminiClose<cr>", desc = "Close Gemini", mode = "n" },
    { "<leader>g>", "<cmd>GeminiWider<cr>", desc = "Gemini Wider", mode = "n" },
    { "<leader>g<", "<cmd>GeminiNarrower<cr>", desc = "Gemini Narrower", mode = "n" },
    { "<C-g>", [[<C-\><C-n><cmd>Gemini<cr>]], desc = "Toggle Gemini", mode = "t" },
  },
}
```

## Workflow Notes

- The terminal pane is pinned to its own split and should stay separate from normal code windows.
- Clicking buffer tabs while focus is inside the terminal should switch files in the code area, not replace the terminal buffer.
- If the active provider suggests a change for a file you are not currently viewing, just open that file and the unified diff should appear there.
- You can review changes either from the editor with `ga` / `gr` or from the CLI with the built-in "Allow" action.
- Since the terminal window is a real split, manual mouse resizing works naturally.

## Extending To Other CLIs

The current plugin ships with a Gemini provider, but the module layout is now set up so new providers can be added without rewriting the editor UX.

The parts that are already generic in spirit:

- terminal split management
- unified diff review UI
- pending diff queue
- buffer refresh and disk sync
- local bridge server and notification flow

The parts that are currently provider-specific:

- startup environment variables such as `GEMINI_CLI_IDE_SERVER_PORT`
- the system-defaults file written in `setup()`
- MCP argument normalization assumptions in the bridge
- command defaults like `terminal_cmd = "gemini"`

The provider registry already lives here:

```text
lua/ai-cli/
  providers/
    init.lua
    gemini.lua
```

Each provider module should own:

- how to build the CLI command
- which environment variables to inject
- any provider-specific defaults files
- request/response normalization for tool calls

The rest of the system should stay provider-agnostic:

- `lua/ai-cli/terminal.lua` manages the pinned terminal split
- `lua/ai-cli/diff.lua` owns the unified diff UI and pending diff queue
- `lua/ai-cli/server.lua` owns the local bridge transport
- `lua/ai-cli/init.lua` wires the active provider into the shared UI and sync flow

To add a new CLI later, the intended path is:

1. add a new provider file such as `lua/ai-cli/providers/claude.lua`
2. expose it from the provider registry
3. implement the same responsibilities as the Gemini provider
4. select it with `provider = "claude"` in `setup()`

That keeps the terminal UX, diff UX, and refresh behavior shared across providers while allowing each CLI to define its own launch contract and bridge semantics.

## License

MIT
