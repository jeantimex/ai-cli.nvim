local rtp = vim.opt.rtp:get()
local current_dir = vim.fn.getcwd()
table.insert(rtp, 1, current_dir)
vim.opt.rtp = rtp

-- Load the plugin
require("ai-cli").setup({
  log_level = "debug",
})
