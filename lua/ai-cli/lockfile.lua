---@module 'ai-cli.lockfile'
--- Manages "lockfiles" (discovery files) used by gemini-cli to find active IDE instances.
--- When the bridge server starts, it writes a JSON file to a well-known temporary directory.
--- The gemini-cli process scans this directory to identify available Neovim instances
--- and retrieve their connection details (port and auth token).
local M = {}

---Returns the standard directory where Gemini discovery files are stored.
---@return string
local function get_lock_dir()
  return vim.fs.joinpath(vim.uv.os_tmpdir(), "gemini", "ide")
end

M.lock_dir = get_lock_dir()

---Generates a unique filename for the discovery file based on PID and Port.
---@param pid number The process ID of Neovim
---@param port number The TCP port the bridge server is listening on
---@return string
local function get_lock_path(pid, port)
  return vim.fs.joinpath(M.lock_dir, string.format("gemini-ide-server-%d-%d.json", pid, port))
end

---Creates a discovery file containing connection details for this Neovim instance.
---@param port number The bridge server port
---@param auth_token string The required Bearer token for authentication
---@return boolean success
---@return string|nil path_or_error
function M.create(port, auth_token)
  local pid = vim.fn.getpid()
  -- Ensure the discovery directory exists
  vim.fn.mkdir(M.lock_dir, "p")

  local lock_path = get_lock_path(pid, port)
  local workspace_path = vim.loop.cwd() or vim.fn.getcwd()

  -- The structure follows a standard expected by gemini-cli
  local lock_content = {
    workspacePath = workspace_path,
    workspaceFolders = { workspace_path },
    ideName = "Neovim",
    ideInfo = {
      name = "vscodefork", -- Used for compatibility with some client detectors
      displayName = "Neovim",
    },
    transport = "http",
    port = port,
    authToken = auth_token,
    pid = pid,
  }

  local file = io.open(lock_path, "w")
  if not file then
    return false, "Failed to create discovery file"
  end

  file:write(vim.json.encode(lock_content))
  file:close()
  return true, lock_path
end

---Deletes the discovery file for the current process.
---Called when the bridge server stops or Neovim exits.
---@param port number
function M.remove(port)
  local lock_path = get_lock_path(vim.fn.getpid(), port)
  os.remove(lock_path)
end

return M
