local M = {}

local function get_lock_dir()
  return vim.fs.joinpath(vim.uv.os_tmpdir(), "gemini", "ide")
end

M.lock_dir = get_lock_dir()

local function get_lock_path(pid, port)
  return vim.fs.joinpath(M.lock_dir, string.format("gemini-ide-server-%d-%d.json", pid, port))
end

function M.create(port, auth_token)
  local pid = vim.fn.getpid()
  vim.fn.mkdir(M.lock_dir, "p")

  local lock_path = get_lock_path(pid, port)
  local workspace_path = vim.loop.cwd() or vim.fn.getcwd()
  local lock_content = {
    workspacePath = workspace_path,
    workspaceFolders = { workspace_path },
    ideName = "Neovim",
    ideInfo = {
      name = "vscodefork",
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

function M.remove(port)
  local lock_path = get_lock_path(vim.fn.getpid(), port)
  os.remove(lock_path)
end

return M
