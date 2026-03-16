local M = {}

function M.read_file(path)
  local fd = assert(io.open(path, "r"))
  local content = fd:read("*a")
  fd:close()
  return content
end

function M.write_file(path, content)
  local fd = assert(io.open(path, "w"))
  fd:write(content)
  fd:close()
end

function M.make_temp_file(content)
  local path = vim.fn.tempname()
  M.write_file(path, content)
  return M.real_path(path)
end

function M.real_path(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

function M.wait(ms, predicate, message)
  local ok = vim.wait(ms, predicate, 10)
  assert(ok, message or ("Timed out after " .. ms .. "ms"))
end

function M.assert_eq(actual, expected, message)
  assert(
    actual == expected,
    message or string.format("Expected %s, got %s", vim.inspect(expected), vim.inspect(actual))
  )
end

return M
