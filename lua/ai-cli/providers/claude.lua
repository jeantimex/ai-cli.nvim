---@module 'ai-cli.providers.claude'
--- Claude Code-specific provider adapter.
--- This adapter prepares a per-session MCP config file and prompt so Claude Code
--- can route edits through ai-cli.nvim's diff review flow.

local M = {
  name = "claude",
}

M.bridge = {
  path = "/mcp",
  auth_token_env_var = "AI_CLI_MCP_AUTH_TOKEN",
}

local function write_mcp_config(bridge_url)
  local path = vim.fs.joinpath(vim.uv.os_tmpdir(), "ai-cli-claude-mcp.json")
  local file = io.open(path, "w")
  if not file then
    return nil, "Failed to create Claude MCP config"
  end

  file:write(vim.json.encode({
    mcpServers = {
      ai_cli_nvim = {
        type = "http",
        url = bridge_url,
        headers = {
          Authorization = "Bearer ${" .. M.bridge.auth_token_env_var .. "}",
        },
      },
    },
  }))
  file:close()
  return path
end

local function write_system_prompt()
  local path = vim.fs.joinpath(vim.uv.os_tmpdir(), "ai-cli-claude-prompt.txt")
  local file = io.open(path, "w")
  if not file then
    return nil, "Failed to create Claude system prompt file"
  end

  file:write(table.concat({
    "When editing project files in this session:",
    "- Do not use Claude Code's built-in editing tools when the ai_cli_nvim MCP tools are available.",
    "- Specifically avoid Edit, MultiEdit, Write, and NotebookEdit for normal source-file changes.",
    "- Read the target file first, then call openDiff with the absolute filePath and the full newContent.",
    "- After proposing a change, wait for the user to review it in Neovim.",
    "- Use getDiffStatus to check whether the review was accepted, rejected, closed, opened, or is still pending.",
    "- If the diff was accepted, continue from the accepted file contents.",
    "- If the diff was rejected or closed, do not assume the change was applied.",
    "",
    "Only fall back to direct file edits when the ai_cli_nvim MCP tools are unavailable.",
    "",
  }, "\n"))
  file:close()
  return path
end

local function read_text_file(path)
  if not path or path == "" then
    return nil
  end

  local file = io.open(path, "r")
  if not file then
    return nil
  end

  local content = file:read("*a")
  file:close()
  return content
end

---@param config table
---@return string
function M.build_command(config)
  return config.terminal_cmd or "claude"
end

---@param config table
---@param prepared_launch AiCliPreparedLaunch
---@return string[]
function M.build_argv(config, prepared_launch)
  local argv = {
    M.build_command(config),
    "--strict-mcp-config",
    "--disallowedTools",
    "Edit,MultiEdit,Write,NotebookEdit",
  }

  if prepared_launch and prepared_launch.mcp_config_path then
    table.insert(argv, "--mcp-config")
    table.insert(argv, prepared_launch.mcp_config_path)
  end

  if prepared_launch and prepared_launch.instructions_path then
    local prompt = read_text_file(prepared_launch.instructions_path)
    if prompt and prompt ~= "" then
      table.insert(argv, "--append-system-prompt")
      table.insert(argv, prompt)
    end

    table.insert(argv, "--append-system-prompt")
    table.insert(argv, "Use ai-cli.nvim MCP diff review tools for code changes and do not fall back to Claude's built-in editing tools unless the MCP tools are unavailable.")
  end

  return argv
end

---@param config table
---@param ctx AiCliProviderLaunchContext
---@return AiCliPreparedLaunch
function M.prepare_launch(config, ctx)
  local env = vim.deepcopy((config or {}).env or {})
  local bridge_url = nil
  local mcp_config_path, mcp_error = nil, nil
  local instructions_path, instructions_error = write_system_prompt()

  if ctx.auth_token then
    env[M.bridge.auth_token_env_var] = ctx.auth_token
  end

  if ctx.bridge_port then
    bridge_url = string.format("http://127.0.0.1:%d%s", ctx.bridge_port, M.bridge.path)
    env.AI_CLI_MCP_SERVER_URL = bridge_url
    mcp_config_path, mcp_error = write_mcp_config(bridge_url)
  end

  return {
    env = env,
    defaults_path = nil,
    defaults_error = mcp_error or instructions_error,
    bridge_url = bridge_url,
    instructions_path = instructions_path,
    mcp_config_path = mcp_config_path,
  }
end

return M
