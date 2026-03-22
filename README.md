# ai-cli.nvim

Neovim integration for coding CLIs.

`ai-cli.nvim` keeps a coding CLI available inside Neovim as a persistent side terminal and opens code suggestions in a reviewable unified diff inside your editor windows.

https://github.com/user-attachments/assets/a4af46c6-eac8-4c2a-91d0-d57b0cb2b451

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
  claude.lua
  init.lua
  codex.lua
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

<img width="1518" height="955" alt="Image" src="https://github.com/user-attachments/assets/25804ed0-beec-4897-9c05-a3453601d31f" />

## Code Suggestions

When the active provider proposes an edit, the plugin opens a dedicated diff review in a temporary buffer.

- `ga` accepts the suggestion, writes it to disk, and updates any open buffers.
- `gr` rejects the suggestion.
- `q` closes the review and rejects it.
- If the target file is not currently visible in Neovim, the suggestion is queued and automatically opens when you visit that file.
- Opening the diff does not have to steal focus from the terminal pane.
- If a suggested change is applied externally from the terminal pane, the diff view is resolved automatically.

The plugin also enables `autoread`, so files modified on disk by the CLI are automatically reloaded in Neovim.

<img width="1518" height="955" alt="Image" src="https://github.com/user-attachments/assets/8086b52d-9b0e-4567-a657-bd6e1aefe8e1" />

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
- `:AiCliBridgeEvents` shows recent MCP bridge tool calls and results

## Minimum Setup

Minimal Gemini setup:

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

Minimal Codex setup:

```lua
{
  "jeantimex/ai-cli.nvim",
  event = "VeryLazy",
  config = function()
    require("ai-cli").setup({
      provider = "codex",
      terminal_cmd = "codex",
    })
  end,
}
```

Minimal Claude setup:

```lua
{
  "jeantimex/ai-cli.nvim",
  event = "VeryLazy",
  config = function()
    require("ai-cli").setup({
      provider = "claude",
      terminal_cmd = "claude",
    })
  end,
}
```

## Gemini CLI Setup

The bundled provider today is Gemini.

Before using the Gemini provider, install `gemini-cli` first:

```sh
npm install -g @google/gemini-cli
```

For more installation details, see:
- https://geminicli.com/

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

## Codex CLI Setup

The plugin now includes an experimental Codex provider.

Before using the Codex provider, install Codex first:

```sh
npm install -g @openai/codex
```

Use this when you want to configure Codex explicitly:

```lua
require("ai-cli").setup({
  provider = "codex",
  terminal_cmd = "codex",
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

The Codex provider currently does three things at launch time:
- injects `AI_CLI_MCP_SERVER_URL`
- injects `AI_CLI_MCP_AUTH_TOKEN`
- passes per-session Codex config overrides so the local Neovim MCP bridge is available without modifying your global Codex config

It also writes a temporary `model_instructions_file` that tells Codex to route code changes through `openDiff` / `getDiffStatus` when those tools are available.

Current caveat:
- Codex support depends on Codex actually following those instructions. The plugin can expose the diff tools, but it cannot force Codex to use them if the model decides to edit files directly.

## Claude Code Setup

The plugin now includes an experimental Claude Code provider.

Before using the Claude provider, install Claude Code first.

Use this when you want to configure Claude explicitly:

```lua
require("ai-cli").setup({
  provider = "claude",
  terminal_cmd = "claude",
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

The Claude provider currently does three things at launch time:
- injects `AI_CLI_MCP_SERVER_URL`
- injects `AI_CLI_MCP_AUTH_TOKEN`
- writes a temporary MCP JSON config and passes it with `--mcp-config --strict-mcp-config`

It also:
- appends a provider-specific system prompt telling Claude Code to route code changes through `openDiff` / `getDiffStatus`
- disables Claude Code's built-in file mutation tools (`Edit`, `MultiEdit`, `Write`, `NotebookEdit`) so the MCP diff flow is preferred

Current caveat:
- Claude support depends on Claude Code actually following that prompt and using the MCP tools instead of editing files directly.

## Verification

Use this sequence for the first live test with Codex or Claude:

1. Open a small file in Neovim that you can safely modify.
2. Start the terminal with `:AiCliOpen`.
3. In the terminal pane, ask the active CLI to make a small edit to the file that is already open.
4. Watch for a diff review buffer to appear in Neovim instead of the file being edited directly on disk.
5. Press `ga` to accept or `gr` to reject.
6. If the diff does not appear and the file changes directly, the provider bypassed the MCP review flow.

Recommended first prompt:

```text
Please make a tiny change to the currently open file by using the diff review tools instead of editing the file directly.
```

What success looks like:
- the target file opens in a unified diff buffer
- the terminal stays open
- accepting the diff writes the file and restores the original buffer
- rejecting the diff leaves the file unchanged

What failure looks like:
- the CLI edits the file directly with no diff buffer
- the CLI says it changed the file, but Neovim never opens a review
- the CLI cannot see the MCP tools

Troubleshooting:
- If Claude says the MCP server failed, fully restart the terminal with `:AiCliClose` and `:AiCliOpen`.
- If Claude still does not open a diff, run `:AiCliBridgeEvents` to inspect the recent MCP calls Claude sent to Neovim.

Example key bindings:

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
  keys = {
    { "<leader>gg", "<cmd>AiCli<cr>", desc = "Toggle AI CLI", mode = "n" },
    { "<leader>go", "<cmd>AiCliOpen<cr>", desc = "Open AI CLI", mode = "n" },
    { "<leader>gc", "<cmd>AiCliClose<cr>", desc = "Close AI CLI", mode = "n" },
    { "<leader>g>", "<cmd>AiCliWider<cr>", desc = "AI CLI Wider", mode = "n" },
    { "<leader>g<", "<cmd>AiCliNarrower<cr>", desc = "AI CLI Narrower", mode = "n" },
    { "<C-g>", [[<C-\><C-n><cmd>AiCli<cr>]], desc = "Toggle AI CLI", mode = "t" },
    { "<M-g>", "<cmd>AiCli<cr>", desc = "Toggle AI CLI", mode = "n" },
    { "<M-g>", [[<C-\><C-n><cmd>AiCli<cr>]], desc = "Toggle AI CLI", mode = "t" },
    { "<C-h>", [[<C-\><C-n><C-w>h]], desc = "Go to left pane", mode = "t" },
    { "<C-l>", [[<C-\><C-n><C-w>l]], desc = "Go to right pane", mode = "t" },
  },
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
- `lua/ai-cli/providers/claude.lua` defines Claude Code-specific command and launch behavior
- `lua/ai-cli/providers/init.lua` resolves the active provider
- `lua/ai-cli/providers/codex.lua` defines Codex-specific command and launch behavior
- `lua/ai-cli/providers/gemini.lua` defines Gemini-specific command and environment behavior

Each provider module should own:
- how to build the CLI command
- how to build provider-specific argv/config overrides
- which environment variables to inject
- any provider-specific defaults files
- any provider-specific instruction files
- request/response normalization for tool calls

To add a new CLI later, the intended path is:

1. add a new provider file such as `lua/ai-cli/providers/claude.lua`
2. expose it from the provider registry
3. implement the same responsibilities as the Gemini provider
4. select it with `provider = "claude"` in `setup()`

That keeps the terminal UX, diff UX, and refresh behavior shared across providers while allowing each CLI to define its own launch contract and bridge semantics.

## License

MIT
