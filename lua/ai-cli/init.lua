---@module 'ai-cli'
--- Main entry point for ai-cli.nvim.
--- This module handles initialization, terminal management, and the bridge server
--- that allows supported coding CLIs to interact with Neovim for code edits.
local M = {}

local logger = require("ai-cli.logger")
local config_module = require("ai-cli.config")
local providers = require("ai-cli.providers")
local terminal = require("ai-cli.terminal")

local server = require("ai-cli.server")
local diff = require("ai-cli.diff")

local defaults_path = nil
local refresh_pending = false

---Refreshes all valid, unmodified file buffers by checking for changes on disk.
---This is debounced to avoid performance hits during rapid file system activity.
local function refresh_open_file_buffers()
  if refresh_pending then
    return
  end

  refresh_pending = true
  -- 150ms debounce window to batch multiple file changes
  vim.defer_fn(function()
    refresh_pending = false

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      -- Only refresh buffers that:
      -- 1. Are valid and loaded
      -- 2. Have a file name (not scratch buffers)
      -- 3. Are normal files (buftype == "")
      -- 4. Are NOT modified (we don't want to overwrite unsaved user changes)
      if vim.api.nvim_buf_is_valid(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" and vim.bo[buf].buftype == "" and not vim.bo[buf].modified then
          -- checktime reloads the buffer from disk if it changed
          pcall(vim.api.nvim_buf_call, buf, function()
            vim.cmd("silent! checktime")
          end)
        end
      end
    end

    diff.sync_external_resolution()
  end, 150)
end

-- Internal module state
M.state = {
  config = config_module.defaults,
  initialized = false,
  provider = nil,
  prepared_launch = nil,
}

---Initialize the plugin with user-provided configuration.
---Sets up logging, terminal settings, diff handling, and starts the bridge server.
---@param user_config table|nil User configuration overrides
function M.setup(user_config)
  -- Merge user config with defaults and initialize sub-modules
  M.state.config = config_module.apply(user_config)
  M.state.provider = providers.get(M.state.config.provider)
  logger.setup(M.state.config)
  terminal.setup(M.state.config.terminal)
  -- The terminal module calls this handler when the user interacts with the terminal
  terminal.set_activity_handler(refresh_open_file_buffers)
  diff.setup(M.state.config)

  -- Start the RPC bridge server. This allows the active CLI process (running in the terminal)
  -- to send commands back to Neovim (e.g., to apply code diffs or open files).
  -- The transport itself is generic enough to survive a later multi-provider refactor;
  -- the provider-specific part is mostly the env/setup contract around it.
  local ok, bridge_port, auth_token = server.start()
  if ok and bridge_port then
    -- Route bridge server events (like code edits) to the diff module for UI handling
    diff.set_event_handler(server.notify)
  else
    logger.warn("init", "IDE bridge failed to start:", bridge_port)
  end

  -- Provider-specific launch preparation lives behind the provider adapter so
  -- this setup flow can stay stable as more CLIs are introduced later.
  M.state.prepared_launch = M.state.provider.prepare_launch(M.state.config, {
    bridge_port = ok and bridge_port or nil,
    auth_token = auth_token,
    pid = vim.fn.getpid(),
  })
  defaults_path = M.state.prepared_launch.defaults_path
  M.state.config.env = M.state.prepared_launch.env or vim.deepcopy(M.state.config.env)
  if M.state.prepared_launch.defaults_error then
    logger.warn("init", "Provider IDE defaults file could not be created.")
  end

  -- Set standard environment variables for Neovim integration.
  -- NVIM is used for 'nvim --remote' and other RPC calls.
  M.state.config.env.NVIM = vim.v.servername
  M.state.config.env.EDITOR = "nvim"

  -- Enable auto-reloading of files. When the active CLI modifies a file on disk,
  -- Neovim will detect it and reload the buffer automatically if it's not modified.
  vim.o.autoread = true
  vim.api.nvim_create_autocmd(
    { "BufEnter", "BufWinEnter", "BufReadPost", "CursorHold", "CursorHoldI", "FocusGained" },
    {
      group = vim.api.nvim_create_augroup("AiCliAutoread", { clear = true }),
      callback = function(args)
        -- Only trigger checktime if not in command-line mode to avoid interrupting the user's typing
        if vim.fn.mode() ~= "c" then
          refresh_open_file_buffers()
        end

        -- If we're entering a buffer that has a pending diff (stored in memory),
        -- offer to show the diff UI.
        if args.event == "BufEnter" or args.event == "BufWinEnter" or args.event == "BufReadPost" then
          diff.maybe_open_pending_for_buffer(args.buf)
          diff.maybe_open_pending()
        end
      end,
    }
  )

  -- Register user-facing commands
  M._create_commands()
  M.state.initialized = true

  logger.debug("init", "AI CLI initialized")
end

---Opens the AI CLI terminal window.
---Initializes the plugin if it hasn't been set up yet.
---@param args string|nil Raw string arguments to pass to the active CLI command
function M.open(args)
  if not M.state.initialized then
    M.setup()
  end

  local argv = M.state.provider.build_argv(M.state.config, M.state.prepared_launch)
  if args and args ~= "" then
    table.insert(argv, args)
  end

  terminal.open(argv, M.state.config.env, M.state.config.terminal, true)
end

---Toggles the AI CLI terminal window visibility.
---@param args string|nil Raw string arguments for the active CLI
function M.toggle(args)
  if not M.state.initialized then
    M.setup()
  end

  local argv = M.state.provider.build_argv(M.state.config, M.state.prepared_launch)
  if args and args ~= "" then
    table.insert(argv, args)
  end

  terminal.toggle(argv, M.state.config.env, M.state.config.terminal)
end

---Closes the AI CLI terminal window.
function M.close()
  terminal.close()
end

function M.set_width(width_percentage)
  local ok, result = terminal.set_width_percentage(width_percentage)
  if not ok then
    logger.error("command", result)
    return
  end

  logger.info("command", string.format("AI CLI width set to %.0f%%.", result * 100))
end

function M.resize(delta)
  local ok, result = terminal.resize(delta)
  if not ok then
    logger.error("command", result)
    return
  end

  logger.info("command", string.format("AI CLI width set to %.0f%%.", result * 100))
end

---Provides a helper to copy the current file path into the active CLI context.
---Currently just logs an instruction, but could be expanded to automate the /add command.
function M.add_current_file()
  local file_path = vim.fn.expand("%:p")
  if file_path == "" then
    logger.error("command", "No file in current buffer")
    return
  end

  logger.info("command", "To add this file, type: /add " .. file_path .. " in the AI CLI terminal")
end

---Registers user-facing commands like :AiCli, :AiCliOpen, etc.
---@private
function M._create_commands()
  local commands = {
    AiCli = {
      fn = function(opts)
        M.toggle(opts.args)
      end,
      opts = {
        nargs = "*",
        desc = "Toggle AI CLI terminal",
      },
    },
    AiCliOpen = {
      fn = function(opts)
        M.open(opts.args)
      end,
      opts = {
        nargs = "*",
        desc = "Open AI CLI terminal",
      },
    },
    AiCliClose = {
      fn = function()
        M.close()
      end,
      opts = {
        desc = "Close AI CLI terminal",
      },
    },
    AiCliWidth = {
      fn = function(opts)
        M.set_width(tonumber(opts.args) / 100)
      end,
      opts = {
        nargs = 1,
        desc = "Set AI CLI terminal width percentage",
      },
    },
    AiCliWider = {
      fn = function()
        M.resize(0.05)
      end,
      opts = {
        desc = "Make AI CLI terminal wider",
      },
    },
    AiCliNarrower = {
      fn = function()
        M.resize(-0.05)
      end,
      opts = {
        desc = "Make AI CLI terminal narrower",
      },
    },
    AiCliAdd = {
      fn = function()
        M.add_current_file()
      end,
      opts = {
        desc = "Add current file to AI CLI context",
      },
    },
    AiCliRefresh = {
      fn = function()
        vim.cmd("checktime")
        logger.info("command", "Buffer reloaded from disk.")
      end,
      opts = {
        desc = "Manually refresh the current buffer from disk.",
      },
    },
  }

  for name, cmd in pairs(commands) do
    vim.api.nvim_create_user_command(name, cmd.fn, cmd.opts)
  end
end

return M
