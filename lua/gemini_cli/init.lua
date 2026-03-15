---@module 'gemini_cli'
--- Main entry point for the gemini-cli.nvim plugin.
--- This module handles initialization, terminal management, and the bridge server
--- that allows gemini-cli to interact with Neovim for code edits.
local M = {}

local logger = require("gemini_cli.logger")
local config_module = require("gemini_cli.config")
local terminal = require("gemini_cli.terminal")

local server = require("gemini_cli.server")
local diff = require("gemini_cli.diff")

-- Path to the temporary system defaults file used to configure gemini-cli
local defaults_path = nil
local refresh_pending = false

---Writes a temporary JSON file containing system-level defaults for gemini-cli.
---This file informs the `gemini-cli` process that it is running inside an IDE
---(Neovim), enabling specialized behavior like the RPC bridge for code edits.
---@return string|nil path The path to the created file, or nil on failure
---@return string|nil error Error message if creation failed
local function write_system_defaults()
  -- Use a predictable path in the OS temporary directory
  local path = vim.fs.joinpath(vim.uv.os_tmpdir(), "gemini-cli.nvim-system-defaults.json")
  local file = io.open(path, "w")
  if not file then
    return nil, "Failed to create Gemini system-defaults file"
  end

  -- Enable IDE mode in the CLI. This tells the CLI to expect an RPC server
  -- on the port provided in GEMINI_CLI_IDE_SERVER_PORT.
  file:write(vim.json.encode({
    ide = {
      enabled = true,
    },
  }))
  file:close()
  return path
end

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
  end, 150)
end

-- Internal module state
M.state = {
  config = config_module.defaults,
  initialized = false,
}

---Initialize the plugin with user-provided configuration.
---Sets up logging, terminal settings, diff handling, and starts the bridge server.
---@param user_config table|nil User configuration overrides
function M.setup(user_config)
  -- Merge user config with defaults and initialize sub-modules
  M.state.config = config_module.apply(user_config)
  logger.setup(M.state.config)
  terminal.setup(M.state.config.terminal)
  -- The terminal module calls this handler when the user interacts with the terminal
  terminal.set_activity_handler(refresh_open_file_buffers)
  diff.setup(M.state.config)

  -- Start the RPC bridge server. This allows the gemini-cli process (running in the terminal)
  -- to send commands back to Neovim (e.g., to apply code diffs or open files).
  local ok, bridge_port = server.start()
  if ok and bridge_port then
    -- Inject environment variables so gemini-cli knows how to connect to this Neovim instance.
    -- These are picked up by the CLI process when it starts in the terminal.
    M.state.config.env.GEMINI_CLI_IDE_SERVER_PORT = tostring(bridge_port)
    M.state.config.env.GEMINI_CLI_IDE_PID = tostring(vim.fn.getpid())
    -- Route bridge server events (like code edits) to the diff module for UI handling
    diff.set_event_handler(server.notify)
  else
    logger.warn("init", "Gemini IDE bridge failed to start:", bridge_port)
  end

  -- Ensure the system defaults file exists for gemini-cli to read.
  -- This file tells the CLI to look for the environment variables above.
  defaults_path = defaults_path or write_system_defaults()
  if defaults_path then
    M.state.config.env.GEMINI_CLI_SYSTEM_DEFAULTS_PATH = defaults_path
  else
    logger.warn("init", "Gemini IDE defaults file could not be created.")
  end

  -- Set standard environment variables for Neovim integration.
  -- NVIM is used for 'nvim --remote' and other RPC calls.
  M.state.config.env.NVIM = vim.v.servername
  M.state.config.env.EDITOR = "nvim"

  -- Enable auto-reloading of files. When gemini-cli modifies a file on disk,
  -- Neovim will detect it and reload the buffer automatically if it's not modified.
  vim.o.autoread = true
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "BufReadPost", "CursorHold", "CursorHoldI", "FocusGained" }, {
    group = vim.api.nvim_create_augroup("GeminiAutoread", { clear = true }),
    callback = function(args)
      -- Only trigger checktime if not in command-line mode to avoid interrupting the user's typing
      if vim.fn.mode() ~= "c" then
        refresh_open_file_buffers()
      end

      -- If we're entering a buffer that has a pending diff from Gemini (stored in memory),
      -- offer to show the diff UI.
      if args.event == "BufEnter" or args.event == "BufWinEnter" or args.event == "BufReadPost" then
        diff.maybe_open_pending_for_buffer(args.buf)
      end
    end,
  })

  -- Register :Gemini* commands
  M._create_commands()
  M.state.initialized = true

  logger.debug("init", "Gemini CLI initialized")
end

---Opens the Gemini terminal window.
---Initializes the plugin if it hasn't been set up yet.
---@param args string|nil Raw string arguments to pass to the gemini-cli command
function M.open(args)
  if not M.state.initialized then
    M.setup()
  end

  local cmd = M.state.config.terminal_cmd
  if args and args ~= "" then
    cmd = cmd .. " " .. args
  end

  terminal.open(cmd, M.state.config.env, M.state.config.terminal, true)
end

---Toggles the Gemini terminal window visibility.
---@param args string|nil Raw string arguments for gemini-cli
function M.toggle(args)
  if not M.state.initialized then
    M.setup()
  end

  local cmd = M.state.config.terminal_cmd
  if args and args ~= "" then
    cmd = cmd .. " " .. args
  end

  terminal.toggle(cmd, M.state.config.env, M.state.config.terminal)
end

---Closes the Gemini terminal window.
function M.close()
  terminal.close()
end

---Provides a helper to copy the current file path into the Gemini context.
---Currently just logs an instruction, but could be expanded to automate the /add command.
function M.add_current_file()
  local file_path = vim.fn.expand("%:p")
  if file_path == "" then
    logger.error("command", "No file in current buffer")
    return
  end

  logger.info("command", "To add this file, type: /add " .. file_path .. " in the Gemini terminal")
end

---Registers user-facing commands like :Gemini, :GeminiOpen, etc.
---@private
function M._create_commands()
  local commands = {
    Gemini = {
      fn = function(opts)
        M.toggle(opts.args)
      end,
      opts = {
        nargs = "*",
        desc = "Toggle Gemini CLI terminal",
      },
    },
    GeminiOpen = {
      fn = function(opts)
        M.open(opts.args)
      end,
      opts = {
        nargs = "*",
        desc = "Open Gemini CLI terminal",
      },
    },
    GeminiClose = {
      fn = function()
        M.close()
      end,
      opts = {
        desc = "Close Gemini CLI terminal",
      },
    },
    GeminiAdd = {
      fn = function()
        M.add_current_file()
      end,
      opts = {
        desc = "Add current file to Gemini context",
      },
    },
    GeminiRefresh = {
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
