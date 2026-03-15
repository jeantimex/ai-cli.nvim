# gemini_cli.nvim

Neovim integration for [gemini_cli](https://github.com/jeantimex/gemini_cli).

This plugin keeps Gemini available inside Neovim as a persistent side terminal and opens code suggestions in a reviewable unified diff inside your editor windows.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "jeantimex/gemini_cli.nvim",
  config = function()
    require("gemini_cli").setup({
      -- your configuration
    })
  end,
}
```

## Configuration

Default configuration:

```lua
require("gemini_cli").setup({
  auto_start = true, -- start the bridge server automatically
  terminal_cmd = "gemini", -- command to start gemini_cli
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

The plugin automatically sets several environment variables for the Gemini terminal:
- `GEMINI_CLI_IDE_SERVER_PORT`: Port for the Neovim bridge server.
- `GEMINI_CLI_IDE_PID`: PID of the Neovim process.
- `NVIM`: Neovim server name.
- `EDITOR`: Set to `nvim`.

## Features

- Persistent Gemini terminal split inside Neovim.
- Native `vsplit` behavior, including mouse drag-resize.
- Terminal session stays alive when you hide and reopen the Gemini pane.
- Gemini terminal buffer is treated like a utility pane (`buflisted = false`, custom filetype).
- Local MCP bridge so Gemini can open and resolve code suggestions directly in Neovim.
- Unified diff review flow with editor-side accept/reject keymaps.
- Deferred diff opening for files that are not currently visible.
- Automatic buffer refresh when Gemini or external commands modify files on disk.
- Editor-side acceptance and Gemini-side "Allow" flows both keep Neovim and Gemini in sync.

## Code Suggestions

When Gemini proposes an edit, the plugin opens a dedicated diff review in a temporary buffer.

- `ga` (default) accepts the suggestion, writes it to disk, and updates any open buffers.
- `gr` (default) rejects the suggestion.
- `q` closes the review and rejects it.
- If Gemini edits a file that is not currently visible in Neovim, the suggestion is queued and automatically opens when you visit that file.
- Opening the diff does not have to steal focus from the Gemini terminal; you can stay in Gemini and press Enter on "Allow".
- If a suggested change is applied externally from the Gemini terminal, the diff view is resolved automatically.

The plugin also enables `autoread`, so files modified on disk by Gemini (if you apply changes via the chat) are automatically reloaded in Neovim.

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
  "jeantimex/gemini_cli.nvim",
  config = function()
    require("gemini_cli").setup()
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

- The Gemini pane is pinned to its own split and should stay separate from normal code windows.
- Clicking buffer tabs while focus is inside Gemini should switch files in the code area, not replace the Gemini terminal.
- If Gemini suggests a change for a file you are not currently viewing, just open that file and the unified diff should appear there.
- You can review changes either from the editor with `ga` / `gr` or from Gemini with the built-in "Allow" action.
- Since the Gemini window is a real split again, manual mouse resizing works naturally.

## License

MIT
