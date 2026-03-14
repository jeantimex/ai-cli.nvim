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
})
```

## Commands

- `:Gemini [args]` - Toggle the Gemini terminal window.
- `:GeminiOpen [args]` - Open the Gemini terminal window.
- `:GeminiClose` - Close the Gemini terminal window.

## License

MIT
