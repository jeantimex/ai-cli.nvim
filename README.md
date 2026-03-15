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

## Code Suggestions

When Gemini proposes an edit, the plugin now opens a dedicated diff review tab.

- `ga` accepts the suggestion and writes it to disk immediately.
- `gr` rejects the suggestion.
- `q` closes the review and rejects it.
- If Gemini edits a file that is not already loaded in Neovim, the suggestion stays pending and the diff opens when you visit that file.

The plugin exposes a local Gemini IDE companion over MCP/HTTP so edit suggestions can open inside Neovim instead of staying only in the Gemini chat pane.

## Commands

- `:Gemini [args]` - Toggle the Gemini terminal window.
- `:GeminiOpen [args]` - Open the Gemini terminal window.
- `:GeminiClose` - Close the Gemini terminal window.

## License

MIT
