# gemini_cli.nvim

Neovim integration for [gemini_cli](https://github.com/jeantimex/gemini_cli).

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
    split_side = "right", -- "left" or "right"
    split_width_percentage = 0.4, -- 40% of screen width
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

## Code Suggestions

When Gemini proposes an edit, the plugin opens a dedicated diff review in a temporary buffer.

- `ga` (default) accepts the suggestion, writes it to disk, and updates any open buffers.
- `gr` (default) rejects the suggestion.
- `q` closes the review and rejects it.
- If Gemini edits a file that is not currently loaded in Neovim, the suggestion is queued and will automatically open the diff review when you visit that file.

The plugin also enables `autoread`, so files modified on disk by Gemini (if you apply changes via the chat) are automatically reloaded in Neovim.

## Commands

- `:Gemini [args]` - Toggle the Gemini terminal window.
- `:GeminiOpen [args]` - Open the Gemini terminal window.
- `:GeminiClose` - Close the Gemini terminal window.
- `:GeminiAdd` - Helper to add the current file to Gemini's context (prints the `/add` command).
- `:GeminiRefresh` - Manually reload the current buffer from disk.

## License

MIT
