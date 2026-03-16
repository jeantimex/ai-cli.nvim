local rtp = vim.opt.rtp:get()
local current_dir = vim.fn.getcwd()
table.insert(rtp, 1, current_dir)
vim.opt.rtp = rtp
vim.o.swapfile = false
