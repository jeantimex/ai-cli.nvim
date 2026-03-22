---@module 'ai-cli.providers.codex'
--- Codex-specific provider adapter.
--- This adapter prepares Codex launch metadata for a later MCP registration step.

local M = {
  name = "codex",
}

M.bridge = {
  transport = "streamable_http",
  path = "/mcp",
  bearer_token_env_var = "AI_CLI_MCP_AUTH_TOKEN",
}

local function write_model_instructions()
  local path = vim.fs.joinpath(vim.uv.os_tmpdir(), "ai-cli-codex-instructions.md")
  local file = io.open(path, "w")
  if not file then
    return nil, "Failed to create Codex instructions file"
  end

  file:write(table.concat({
    "# ai-cli.nvim Codex instructions",
    "",
    "When editing project files in this session:",
    "- Do not modify files directly when the `openDiff` tool is available.",
    "- Read the target file first, then call `openDiff` with the absolute `filePath` and the complete proposed `newContent`.",
    "- After proposing a change, wait for the user to review it in Neovim.",
    "- Use `getDiffStatus` to check whether the diff was accepted, rejected, closed, opened, or is still pending.",
    "- If the diff was accepted, continue from the accepted file contents.",
    "- If the diff was rejected or closed, do not assume the change was applied.",
    "",
    "Only fall back to direct file edits when the diff review tools are unavailable.",
    "",
  }, "\n"))
  file:close()
  return path
end

---@param config table
---@return string
function M.build_command(config)
  return config.terminal_cmd or "codex"
end

---@param config table
---@param prepared_launch AiCliPreparedLaunch
---@return string[]
function M.build_argv(config, prepared_launch)
  local argv = { M.build_command(config) }

  table.insert(argv, "-c")
  table.insert(argv, "hide_agent_reasonings=true")
  table.insert(argv, "-c")
  table.insert(argv, "show_raw_agent_reasoning=false")
  table.insert(argv, "-c")
  table.insert(argv, 'model_verbosity="low"')

  if prepared_launch and prepared_launch.bridge_url then
    table.insert(argv, "-c")
    table.insert(argv, string.format('mcp_servers.ai_cli_nvim.url="%s"', prepared_launch.bridge_url))
    table.insert(argv, "-c")
    table.insert(
      argv,
      string.format('mcp_servers.ai_cli_nvim.bearer_token_env_var="%s"', M.bridge.bearer_token_env_var)
    )
  end

  if prepared_launch and prepared_launch.instructions_path then
    table.insert(argv, "-c")
    table.insert(argv, string.format('model_instructions_file="%s"', prepared_launch.instructions_path))
  end

  return argv
end

---@param config table
---@param ctx AiCliProviderLaunchContext
---@return AiCliPreparedLaunch
function M.prepare_launch(config, ctx)
  local env = vim.deepcopy((config or {}).env or {})
  local bridge_url = nil
  local instructions_path, instructions_error = write_model_instructions()

  if ctx.bridge_port then
    bridge_url = string.format("http://127.0.0.1:%d%s", ctx.bridge_port, M.bridge.path)
    env.AI_CLI_MCP_SERVER_URL = bridge_url
  end
  if ctx.auth_token then
    env[M.bridge.bearer_token_env_var] = ctx.auth_token
  end

  return {
    env = env,
    defaults_path = nil,
    defaults_error = instructions_error,
    bridge_url = bridge_url,
    instructions_path = instructions_path,
  }
end

return M
