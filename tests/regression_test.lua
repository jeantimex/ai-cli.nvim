local helpers = dofile("tests/helpers.lua")

local config = require("ai-cli.config")
local providers = require("ai-cli.providers")
local diff = require("ai-cli.diff")

local function with_clean_buffer()
  vim.cmd("enew")
end

local function test_config_and_provider()
  local merged = config.apply({
    terminal = {
      split_width_percentage = 0.55,
    },
  })

  helpers.assert_eq(merged.provider, "gemini", "Default provider should remain gemini")
  helpers.assert_eq(merged.terminal.split_width_percentage, 0.55, "Terminal width override should merge deeply")

  local ok = pcall(config.apply, {
    terminal = {
      split_width_percentage = 2,
    },
  })
  assert(not ok, "Invalid terminal width should fail validation")

  local provider = providers.get("gemini")
  helpers.assert_eq(provider.name, "gemini", "Gemini provider should be resolved from registry")
  helpers.assert_eq(
    provider.build_command({ terminal_cmd = "my-gemini" }),
    "my-gemini",
    "Provider should respect terminal_cmd"
  )

  local prepared = provider.prepare_launch({
    env = { EXISTING = "1" },
  }, {
    bridge_port = 7777,
    auth_token = "secret",
    pid = 1234,
  })
  local env = prepared.env
  helpers.assert_eq(env.EXISTING, "1", "Provider env merge should preserve existing keys")
  helpers.assert_eq(env.GEMINI_CLI_IDE_SERVER_PORT, "7777", "Provider should set bridge port env")
  helpers.assert_eq(env.GEMINI_CLI_IDE_PID, "1234", "Provider should set pid env")
  assert(type(prepared.defaults_path) == "string" and prepared.defaults_path ~= "", "Gemini defaults path should be set")
  helpers.assert_eq(env.GEMINI_CLI_SYSTEM_DEFAULTS_PATH, prepared.defaults_path, "Provider should set defaults path env")

  local codex = providers.get("codex")
  helpers.assert_eq(codex.name, "codex", "Codex provider should be resolved from registry")
  helpers.assert_eq(codex.build_command({ terminal_cmd = "my-codex" }), "my-codex", "Codex should respect terminal_cmd")

  local codex_prepared = codex.prepare_launch({
    env = { EXISTING = "1" },
  }, {
    bridge_port = 8123,
    auth_token = "codex-token",
    pid = 4321,
  })
  helpers.assert_eq(codex_prepared.env.EXISTING, "1", "Codex env merge should preserve existing keys")
  helpers.assert_eq(
    codex_prepared.env.AI_CLI_MCP_SERVER_URL,
    "http://127.0.0.1:8123/mcp",
    "Codex provider should expose the local MCP server URL"
  )
  helpers.assert_eq(
    codex_prepared.env.AI_CLI_MCP_AUTH_TOKEN,
    "codex-token",
    "Codex provider should expose the MCP bearer token"
  )
  helpers.assert_eq(codex_prepared.defaults_path, nil, "Codex provider should not write provider defaults")
  assert(
    type(codex_prepared.instructions_path) == "string" and codex_prepared.instructions_path ~= "",
    "Codex provider should create a model instructions file"
  )

  local codex_argv = codex.build_argv({ terminal_cmd = "my-codex" }, codex_prepared)
  helpers.assert_eq(codex_argv[1], "my-codex", "Codex argv should start with the configured command")
  local argv_joined = table.concat(codex_argv, "\n")
  assert(argv_joined:match("hide_agent_reasonings=true"), "Codex argv should hide agent reasonings")
  assert(argv_joined:match("show_raw_agent_reasoning=false"), "Codex argv should disable raw reasoning output")
  assert(argv_joined:match('model_verbosity="low"'), "Codex argv should lower verbosity")
  assert(argv_joined:match('mcp_servers%.ai_cli_nvim%.url="http://127%.0%.0%.1:8123/mcp"'), "Codex argv should register the MCP bridge URL")
  assert(
    argv_joined:match('mcp_servers%.ai_cli_nvim%.bearer_token_env_var="AI_CLI_MCP_AUTH_TOKEN"'),
    "Codex argv should register the bearer token env var"
  )
  assert(
    argv_joined:match('model_instructions_file="'),
    "Codex argv should pass the Codex model instructions file"
  )

  local claude = providers.get("claude")
  helpers.assert_eq(claude.name, "claude", "Claude provider should be resolved from registry")
  helpers.assert_eq(claude.build_command({ terminal_cmd = "my-claude" }), "my-claude", "Claude should respect terminal_cmd")

  local claude_prepared = claude.prepare_launch({
    env = { EXISTING = "1" },
  }, {
    bridge_port = 9234,
    auth_token = "claude-token",
    pid = 5678,
  })
  helpers.assert_eq(claude_prepared.env.EXISTING, "1", "Claude env merge should preserve existing keys")
  helpers.assert_eq(
    claude_prepared.env.AI_CLI_MCP_SERVER_URL,
    "http://127.0.0.1:9234/mcp",
    "Claude provider should expose the local MCP server URL"
  )
  helpers.assert_eq(
    claude_prepared.env.AI_CLI_MCP_AUTH_TOKEN,
    "claude-token",
    "Claude provider should expose the MCP auth token"
  )
  assert(
    type(claude_prepared.instructions_path) == "string" and claude_prepared.instructions_path ~= "",
    "Claude provider should create a system prompt file"
  )
  assert(
    type(claude_prepared.mcp_config_path) == "string" and claude_prepared.mcp_config_path ~= "",
    "Claude provider should create an MCP config file"
  )

  local claude_argv = claude.build_argv({ terminal_cmd = "my-claude" }, claude_prepared)
  helpers.assert_eq(claude_argv[1], "my-claude", "Claude argv should start with the configured command")
  local claude_joined = table.concat(claude_argv, "\n")
  assert(claude_joined:match("%-%-strict%-mcp%-config"), "Claude argv should use strict MCP config")
  assert(claude_joined:match("%-%-mcp%-config"), "Claude argv should pass an MCP config file")
  assert(claude_joined:match("%-%-append%-system%-prompt"), "Claude argv should append a system prompt")
  assert(
    claude_joined:match("%-%-disallowedTools"),
    "Claude argv should disallow built-in edit tools so MCP diff review is used"
  )
  assert(
    claude_joined:match("Edit,MultiEdit,Write,NotebookEdit"),
    "Claude argv should disable the built-in Claude edit tools"
  )
end

local function test_editor_accept_flow()
  with_clean_buffer()
  local path = helpers.make_temp_file("before\n")

  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local result = diff.open_diff({
    filePath = path,
    newContent = "after\n",
  })

  helpers.assert_eq(result.status, "opened", "Visible files should open a review immediately")
  helpers.assert_eq(vim.bo.filetype, "diff", "Review buffer should use diff filetype")

  local keymaps = vim.api.nvim_buf_get_keymap(0, "n")
  local has_accept = false
  local has_reject = false
  for _, map in ipairs(keymaps) do
    if map.lhs == "ga" then
      has_accept = true
    elseif map.lhs == "gr" then
      has_reject = true
    end
  end
  assert(has_accept, "Review buffer should expose the apply mapping")
  assert(has_reject, "Review buffer should expose the reject mapping")

  vim.cmd("normal ga")

  helpers.wait(200, function()
    return helpers.read_file(path) == "after\n"
  end, "Accepted diff should write the proposed content to disk")

  helpers.assert_eq(
    vim.api.nvim_buf_get_name(0),
    vim.fs.normalize(path),
    "Original file buffer should be restored after apply"
  )

  local closed = diff.close_diff(path)
  helpers.assert_eq(closed.status, "accepted", "Accepted diff should be remembered as accepted")
  helpers.assert_eq(closed.acceptedInEditor, true, "Accepted diff should report editor acceptance")
  helpers.assert_eq(closed.finalContent, "after\n", "Accepted diff should return final content")
end

local function test_pending_diff_opens_when_file_is_visited()
  with_clean_buffer()
  local unrelated = helpers.make_temp_file("unrelated\n")
  local target = helpers.make_temp_file("old\n")

  vim.cmd("edit " .. vim.fn.fnameescape(unrelated))
  local result = diff.open_diff({
    filePath = target,
    newContent = "new\n",
  })

  helpers.assert_eq(result.status, "pending", "Hidden file diffs should stay pending")

  vim.cmd("edit " .. vim.fn.fnameescape(target))
  diff.maybe_open_pending_for_buffer(0)

  helpers.wait(300, function()
    return vim.bo.filetype == "diff"
  end, "Pending diff should open when the target file is visited")

  local closed = diff.close_diff(target)
  helpers.assert_eq(closed.status, "closed", "Closing an active pending diff should report a closed review")
  helpers.assert_eq(closed.finalContent, "new\n", "Closed review should still return proposed content")
  helpers.assert_eq(
    vim.api.nvim_buf_get_name(0),
    vim.fs.normalize(target),
    "Closing a review should restore the target file buffer"
  )
end

local function test_get_diff_status_is_non_destructive()
  with_clean_buffer()
  local target = helpers.make_temp_file("before\n")

  vim.cmd("edit " .. vim.fn.fnameescape(target))
  local result = diff.open_diff({
    filePath = target,
    newContent = "after\n",
  })

  helpers.assert_eq(result.status, "opened", "Visible file should open review immediately")

  local status = diff.get_diff_status(target)
  helpers.assert_eq(status.status, "opened", "Status check should report an open review")
  helpers.assert_eq(status.finalContent, "after\n", "Status check should preserve proposed content")
  helpers.assert_eq(vim.bo.filetype, "diff", "Status check should not close the review buffer")

  local closed = diff.close_diff(target)
  helpers.assert_eq(closed.status, "closed", "Explicit close should still close the review")
end

local function test_pending_external_resolution()
  with_clean_buffer()
  local unrelated = helpers.make_temp_file("unrelated\n")
  local target = helpers.make_temp_file("before\n")

  vim.cmd("edit " .. vim.fn.fnameescape(unrelated))
  local result = diff.open_diff({
    filePath = target,
    newContent = "accepted externally\n",
  })

  helpers.assert_eq(result.status, "pending", "Pending diff should be queued before external resolution")

  helpers.write_file(target, "accepted externally\n")
  diff.sync_external_resolution()

  local closed = diff.close_diff(target)
  helpers.assert_eq(closed.status, "accepted", "Externally applied pending diff should resolve as accepted")
  helpers.assert_eq(closed.acceptedInEditor, true, "External resolution should be reported as accepted")
  helpers.assert_eq(closed.finalContent, "accepted externally\n", "External resolution should preserve final content")
end

local function test_active_external_resolution()
  with_clean_buffer()
  local target = helpers.make_temp_file("before\n")

  vim.cmd("edit " .. vim.fn.fnameescape(target))
  local result = diff.open_diff({
    filePath = target,
    newContent = "active external apply\n",
  })

  helpers.assert_eq(result.status, "opened", "Visible file should open review before external apply")
  helpers.write_file(target, "active external apply\n")
  diff.sync_external_resolution()

  local closed = diff.close_diff(target)
  helpers.assert_eq(closed.status, "accepted", "Externally applied active diff should resolve as accepted")
  helpers.assert_eq(closed.acceptedInEditor, true, "Resolved active diff should be marked accepted")
  helpers.assert_eq(closed.finalContent, "active external apply\n", "Resolved active diff should keep final content")
end

test_config_and_provider()
test_editor_accept_flow()
test_pending_diff_opens_when_file_is_visited()
test_get_diff_status_is_non_destructive()
test_pending_external_resolution()
test_active_external_resolution()

print("All regression tests passed!")
