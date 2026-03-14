-- Basic test script for gemini_cli.nvim

-- Set up the runtime path
local rtp = vim.opt.rtp:get()
local current_dir = vim.fn.getcwd()
table.insert(rtp, 1, current_dir)
vim.opt.rtp = rtp

-- Load the plugin
local gemini_cli = require("gemini_cli")
gemini_cli.setup({
  log_level = "debug",
})

-- Test module existence
assert(gemini_cli ~= nil, "gemini_cli module should be loaded")

-- Test command registration
local commands = vim.api.nvim_get_commands({})
assert(commands["Gemini"] ~= nil, "Gemini command should be registered")
assert(commands["GeminiOpen"] ~= nil, "GeminiOpen command should be registered")
assert(commands["GeminiClose"] ~= nil, "GeminiClose command should be registered")

print("All basic tests passed!")
