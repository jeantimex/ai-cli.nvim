-- Basic test script for ai-cli namespace

-- Set up the runtime path
local rtp = vim.opt.rtp:get()
local current_dir = vim.fn.getcwd()
table.insert(rtp, 1, current_dir)
vim.opt.rtp = rtp

-- Load the plugin
local ai_cli = require("ai-cli")
ai_cli.setup({
  log_level = "error",
})

-- Test module existence
assert(ai_cli ~= nil, "ai-cli module should be loaded")

-- Test command registration
local commands = vim.api.nvim_get_commands({})
assert(commands["AiCli"] ~= nil, "AiCli command should be registered")
assert(commands["AiCliOpen"] ~= nil, "AiCliOpen command should be registered")
assert(commands["AiCliClose"] ~= nil, "AiCliClose command should be registered")

print("All basic tests passed!")
