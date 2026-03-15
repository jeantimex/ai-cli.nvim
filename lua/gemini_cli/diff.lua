local M = {}
local logger = require("gemini_cli.logger")

local active_diffs = {}
local resolved_diffs = {}
local event_handler = nil

local ignored_filetypes = {
  ["NvimTree"] = true,
  ["neo-tree"] = true,
  ["oil"] = true,
  ["minifiles"] = true,
  ["snacks_picker_input"] = true,
  ["snacks_picker_list"] = true,
  ["snacks_picker_preview"] = true,
}

local function schedule_ui(fn)
  vim.schedule(function()
    local ok, err = pcall(fn)
    if not ok then
      logger.error("diff", err)
    end
  end)
end

local function normalize_path(path)
  if not path or path == "" then
    return nil
  end

  return vim.fs.normalize(path)
end

local function read_file(path)
  local fd = vim.uv.fs_open(path, "r", 420)
  if not fd then
    return ""
  end

  local stat = vim.uv.fs_fstat(fd)
  if not stat or stat.size == 0 then
    vim.uv.fs_close(fd)
    return ""
  end

  local data = vim.uv.fs_read(fd, stat.size, 0) or ""
  vim.uv.fs_close(fd)
  return data
end

local function write_file(path, content)
  local dir = vim.fs.dirname(path)
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end

  local fd, err = vim.uv.fs_open(path, "w", 420)
  if not fd then
    return false, err
  end

  local ok, write_err = vim.uv.fs_write(fd, content, 0)
  vim.uv.fs_close(fd)
  if not ok then
    return false, write_err
  end

  return true
end

local function split_lines(content)
  if content == "" then
    return { "" }
  end

  return vim.split(content, "\n", { plain = true })
end

local function ensure_trailing_newline(content)
  if content == "" or content:sub(-1) == "\n" then
    return content
  end

  return content .. "\n"
end

local function build_unified_diff(original_content, new_content)
  local diff = vim.diff(ensure_trailing_newline(original_content), ensure_trailing_newline(new_content), {
    result_type = "unified",
    ctxlen = 3,
    algorithm = "myers",
  })

  if not diff or diff == "" then
    diff = "@@ no changes @@\n"
  end

  return vim.split(diff, "\n", { plain = true })
end

local function sync_loaded_buffers(path, content)
  local normalized = normalize_path(path)
  local lines = split_lines(content)

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) ~= "" then
      local buf_name = normalize_path(vim.api.nvim_buf_get_name(buf))
      if buf_name == normalized and not vim.bo[buf].modified then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modified = false
      end
    end
  end
end

local function choose_review_window()
  local current_tab = vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(current_tab)
  local best_win = nil
  local best_score = -1

  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local buftype = vim.bo[buf].buftype
      local filetype = vim.bo[buf].filetype
      if buftype == "" and not ignored_filetypes[filetype] then
        local width = vim.api.nvim_win_get_width(win)
        local height = vim.api.nvim_win_get_height(win)
        local score = width * height
        if score > best_score then
          best_score = score
          best_win = win
        end
      end
    end
  end

  return best_win or vim.api.nvim_get_current_win()
end

local function make_review_buffer(path, diff_lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "Gemini Diff: " .. path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, diff_lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = "diff"
  return buf
end

local function render_help(buf, state)
  vim.api.nvim_buf_clear_namespace(buf, state.help_ns, 0, 1)
  vim.api.nvim_buf_set_extmark(buf, state.help_ns, 0, 0, {
    virt_text = {
      { " " .. state.accept_key .. " apply ", "DiffAdd" },
      { " " .. state.reject_key .. " reject ", "DiffDelete" },
      { " q close ", "Comment" },
    },
    virt_text_pos = "right_align",
  })
end

local function cleanup_state(state)
  if state.group then
    pcall(vim.api.nvim_del_augroup_by_id, state.group)
  end

  if state.review_win and vim.api.nvim_win_is_valid(state.review_win) then
    if state.original_buf and vim.api.nvim_buf_is_valid(state.original_buf) then
      vim.api.nvim_win_set_buf(state.review_win, state.original_buf)
      if state.original_cursor then
        pcall(vim.api.nvim_win_set_cursor, state.review_win, state.original_cursor)
      end
    elseif state.review_buf and vim.api.nvim_buf_is_valid(state.review_buf) then
      pcall(vim.api.nvim_buf_delete, state.review_buf, { force = true })
    end
  elseif state.review_buf and vim.api.nvim_buf_is_valid(state.review_buf) then
    pcall(vim.api.nvim_buf_delete, state.review_buf, { force = true })
  end
end

local function close_state(file_path)
  local key = normalize_path(file_path)
  local state = key and active_diffs[key] or nil
  if not state then
    return nil
  end

  active_diffs[key] = nil
  cleanup_state(state)
  return state
end

local function remember_result(file_path, result)
  local key = normalize_path(file_path)
  if not key then
    return
  end

  result.filePath = key
  result.resolvedAt = vim.uv.hrtime()
  resolved_diffs[key] = result
end

local function emit_event(method, params)
  if not event_handler then
    return
  end

  local ok, err = pcall(event_handler, method, params)
  if not ok then
    logger.warn("diff", "Failed to notify Gemini bridge:", err)
  end
end

local function get_state(file_path)
  local key = normalize_path(file_path)
  if not key then
    return nil, "No file path provided"
  end

  local state = active_diffs[key]
  if not state then
    return nil, "No active diff for " .. key
  end

  return state
end

local function finalize_in_editor(file_path, accepted)
  local state, err = get_state(file_path)
  if not state then
    return false, err
  end

  state.accepted = accepted == true
  state.resolved = true
  state.final_content = state.new_content

  local result = {
    acceptedInEditor = state.accepted,
    finalContent = state.accepted and state.new_content or nil,
    status = state.accepted and "accepted" or "rejected",
  }

  if accepted then
    local ok, write_err = write_file(state.old_file, state.new_content)
    if not ok then
      state.accepted = false
      state.resolved = false
      return false, write_err
    end

    sync_loaded_buffers(state.old_file, state.new_content)
    remember_result(state.old_file, result)
    emit_event("ide/diffAccepted", {
      filePath = state.old_file,
      content = state.new_content,
    })
    logger.info("diff", "Changes applied in editor for " .. vim.fn.fnamemodify(state.old_file, ":."))
  else
    remember_result(state.old_file, result)
    emit_event("ide/diffRejected", {
      filePath = state.old_file,
    })
    logger.info("diff", "Changes rejected in editor for " .. vim.fn.fnamemodify(state.old_file, ":."))
  end

  close_state(file_path)
  return true
end

local function set_keymaps(buf, state)
  local opts = { buffer = buf, silent = true, nowait = true }

  vim.keymap.set("n", state.accept_key, function()
    local ok, err = finalize_in_editor(state.old_file, true)
    if not ok then
      logger.error("diff", "Failed to apply changes:", err or "unknown error")
    end
  end, vim.tbl_extend("force", opts, { desc = "Apply Gemini changes" }))

  vim.keymap.set("n", state.reject_key, function()
    finalize_in_editor(state.old_file, false)
  end, vim.tbl_extend("force", opts, { desc = "Reject Gemini changes" }))

  vim.keymap.set("n", "q", function()
    finalize_in_editor(state.old_file, false)
  end, vim.tbl_extend("force", opts, { desc = "Close Gemini diff" }))
end

function M.setup(config)
  M.config = config or {}
end

function M.set_event_handler(handler)
  event_handler = handler
end

function M.open_diff(params)
  if vim.in_fast_event() then
    schedule_ui(function()
      M.open_diff(params)
    end)

    return {
      filePath = normalize_path(params.old_file_path or params.filePath or params.path),
      status = "scheduled",
    }
  end

  local old_file = normalize_path(params.old_file_path or params.filePath or params.path)
  local new_content = params.new_file_contents or params.newContent or params.newText or ""
  local accept_key = (((M.config or {}).diff or {}).accept_key) or "ga"
  local reject_key = (((M.config or {}).diff or {}).reject_key) or "gr"

  if not old_file then
    error("No target file path provided for diff request.")
  end

  close_state(old_file)

  local review_win = choose_review_window()
  local original_buf = vim.api.nvim_win_get_buf(review_win)
  local original_cursor = vim.api.nvim_win_get_cursor(review_win)
  local original_content = read_file(old_file)
  local review_buf = make_review_buffer(old_file, build_unified_diff(original_content, new_content))
  local unique_id = tostring(vim.uv.hrtime())
  local state = {
    accept_key = accept_key,
    accepted = false,
    final_content = nil,
    group = vim.api.nvim_create_augroup("GeminiCliDiff" .. unique_id, { clear = true }),
    help_ns = vim.api.nvim_create_namespace("GeminiCliDiffHelp" .. unique_id),
    new_content = new_content,
    old_file = old_file,
    original_buf = original_buf,
    original_content = original_content,
    original_cursor = original_cursor,
    reject_key = reject_key,
    resolved = false,
    review_buf = review_buf,
    review_win = review_win,
  }
  active_diffs[old_file] = state

  vim.api.nvim_win_set_buf(review_win, review_buf)
  vim.wo[review_win].wrap = false
  vim.wo[review_win].number = false
  vim.wo[review_win].relativenumber = false
  vim.wo[review_win].cursorline = true
  vim.wo[review_win].signcolumn = "no"

  set_keymaps(review_buf, state)
  render_help(review_buf, state)

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = state.group,
    buffer = review_buf,
    callback = function()
      if active_diffs[old_file] and not active_diffs[old_file].resolved then
        finalize_in_editor(old_file, false)
      end
    end,
  })

  vim.api.nvim_set_current_win(review_win)
  logger.info("diff", "Opened Gemini diff for " .. vim.fn.fnamemodify(old_file, ":."))

  return {
    filePath = old_file,
    status = "opened",
  }
end

function M.close_diff(file_path)
  local key = normalize_path(file_path)
  if vim.in_fast_event() then
    local resolved = key and resolved_diffs[key] or nil
    if resolved then
      return {
        filePath = resolved.filePath,
        acceptedInEditor = resolved.acceptedInEditor == true,
        status = resolved.status,
        finalContent = resolved.finalContent,
      }
    end

    local state = key and active_diffs[key] or nil
    if state then
      schedule_ui(function()
        M.close_diff(file_path)
      end)

      return {
        filePath = key,
        status = "scheduled",
        finalContent = state.new_content,
      }
    end
  end

  local state, err = get_state(file_path)
  if not state then
    local resolved = key and resolved_diffs[key] or nil
    if resolved then
      return {
        filePath = resolved.filePath,
        acceptedInEditor = resolved.acceptedInEditor == true,
        status = resolved.status,
        finalContent = resolved.finalContent,
      }
    end

    return {
      filePath = key,
      status = "not_found",
      error = err,
    }
  end

  local result = {
    filePath = state.old_file,
    acceptedInEditor = state.accepted == true,
    status = state.accepted and "accepted" or "closed",
    finalContent = state.new_content,
  }

  close_state(file_path)
  remember_result(state.old_file, result)
  return result
end

return M
