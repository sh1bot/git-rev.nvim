-- gitrev: in-fill buffers whose name looks like a git revision.
--
-- When Neovim is asked to edit a file that does not exist, we inspect the name.
-- If it parses as a git revision and resolves to a blob in the repository, we
-- load that blob's content into the buffer, mark it read-only, and give it the
-- filetype of the file it stands in for.
--
-- Design constraints (from the request):
--   * Cheap disambiguation first, git second.  We never shell out for a name
--     that is not revision-shaped (see M.parse -- pure, no vim, no filesystem).
--   * Minimal external calls.  A successful in-fill costs two git invocations
--     (one metadata probe, one blob read); a miss costs at most one (two when an
--     explicit path is retried under a fallback interpretation).
--   * No stalls.  Every git call goes through vim.system with a timeout, so a
--     slow or hung git cannot freeze the editor.
--   * Guard against large, binary, and huge-line-count blobs.
--
-- Requires Neovim 0.10+ (vim.system).

local M = {}

M.config = {
  enabled = true,
  -- Maximum blob size to load, in bytes.  Larger blobs are skipped with a
  -- warning and the buffer falls through to normal new-file behaviour.
  max_size = 10 * 1024 * 1024,
  -- Maximum number of lines to load.  Bounds the worst-case time to populate
  -- the buffer for blobs that are within max_size but have a huge line count
  -- (e.g. millions of tiny lines); the read is aborted as soon as it is
  -- exceeded, so it costs nothing beyond one read buffer.
  max_lines = 500000,
  -- Hard ceiling on how long any single git call may run, in milliseconds.
  timeout = 2000,
  -- Minimum length for a bare hex token to be treated as an object id.
  min_hex = 7,
  -- Emit notifications for guard trips (too large / binary).
  notify = true,
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

--------------------------------------------------------------------------------
-- Name parsing (pure: no vim, no filesystem, no git).
--
-- Answers, syntactically only: does this name look enough like a git revision
-- that we should try to resolve it, and if so what are the rev and (maybe) path?
-- The "does it actually exist" check happens later, in git.
--------------------------------------------------------------------------------

-- Characters git uses in revision expressions but which essentially never
-- appear in an about-to-be-created filename (colon is handled separately as the
-- path separator; dots and dashes are excluded as they are common in names).
local REV_PUNCT = "[%^~@{}]"

-- Git's own default abbreviation length (core.abbrev) is 7; a good floor that
-- admits realistic short ids while rejecting 4-letter hex words ("dead").
local DEFAULT_MIN_HEX = 7

local function looks_hex(s, min_hex)
  min_hex = min_hex or DEFAULT_MIN_HEX
  return s:match("^%x+$") ~= nil and #s >= min_hex and #s <= 64
end

--- Parse a buffer name into a revision spec, or nil when it is not
--- revision-shaped.  Spec fields: rev (string) and path (string|nil); a nil
--- path means the filename has to be deduced from context.
function M.parse(name, opts)
  opts = opts or {}
  if type(name) ~= "string" or name == "" then
    return nil
  end
  -- Ignore URL-like virtual buffers from other plugins (fugitive://, oil://,
  -- term://, http://, ...).
  if name:match("^%w[%w+.%-]*://") then
    return nil
  end

  local colon = name:find(":", 1, true)
  if colon then
    local rev = name:sub(1, colon - 1)
    local path = name:sub(colon + 1)
    -- A Windows drive letter ("C:\foo", "C:/foo") is not rev:path.
    if #rev == 1 and rev:match("%a") and path:match("^[/\\]") then
      return nil
    end
    if path == "" then
      -- Trailing colon: explicit "treat as revision, deduce filename".
      if rev == "" then
        return nil
      end
      return { rev = rev, path = nil }
    end
    -- rev:path (git blob syntax); empty rev is git's index notation (:path).
    return { rev = rev, path = path }
  end

  -- No colon: a revision only when hex, or carrying git revision punctuation.
  -- Plain tokens (HEAD, master, v1.2.3, README) are left alone; use "HEAD:" to
  -- force one of those.
  if looks_hex(name, opts.min_hex) or name:match(REV_PUNCT) then
    return { rev = name, path = nil }
  end
  return nil
end

--------------------------------------------------------------------------------
-- git layer (vim.system: argv list -- no shell, raw bytes, first-class timeout).
--------------------------------------------------------------------------------

local function warn(msg)
  if M.config.notify then
    vim.notify("[gitrev] " .. msg, vim.log.levels.WARN)
  end
end

local GIT_ENV = { GIT_TERMINAL_PROMPT = "0", GIT_OPTIONAL_LOCKS = "0" }

-- Probe an object with a single `git cat-file --batch-check`.  Returns
-- { oid, type, size } or nil (missing / not a repo / timed out / errored).
local function probe(dir, object)
  local res = vim.system({ "git", "-C", dir, "cat-file", "--batch-check" }, {
    stdin = object .. "\n",
    env = GIT_ENV,
    timeout = M.config.timeout,
  }):wait()
  if res.code ~= 0 or not res.stdout then
    return nil
  end
  -- "<oid> <type> <size>" on success, "<object> missing" otherwise.
  local oid, otype, size = vim.trim(res.stdout):match("^(%x+)%s+(%S+)%s+(%d+)$")
  if not oid then
    return nil
  end
  return { oid = oid, type = otype, size = tonumber(size) }
end

-- Read a blob's lines by oid, or nil on error/timeout/binary/too-many-lines.
-- vim.system captures stdout as raw bytes (NULs and all) and enforces the
-- timeout itself, so we work on the exact content: reject on a NUL byte (git's
-- binary signal, and a byte a buffer line cannot hold), bail past max_lines
-- before splitting so a pathological blob never builds a giant list, then split.
local function read_blob(dir, oid, object)
  local res = vim.system({ "git", "-C", dir, "cat-file", "blob", oid }, {
    text = false,
    env = GIT_ENV,
    timeout = M.config.timeout,
  }):wait()
  if res.code ~= 0 or not res.stdout then
    return nil
  end
  local data = res.stdout

  if data:find("\0", 1, true) then
    warn(object .. " looks binary; leaving as a new file")
    return nil
  end

  -- Count newlines, bailing past the cap without building the line list.
  local count, pos = 0, 0
  while true do
    pos = data:find("\n", pos + 1, true)
    if not pos then
      break
    end
    count = count + 1
    if count > M.config.max_lines then
      warn(string.format("%s exceeds max_lines (%d); leaving as a new file",
        object, M.config.max_lines))
      return nil
    end
  end

  local lines = vim.split(data, "\n", { plain = true })
  -- git blobs normally end in "\n", giving a trailing empty item; drop it so we
  -- do not add a spurious blank final line (readfile semantics).
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

--------------------------------------------------------------------------------
-- Locating the file / repo.
--------------------------------------------------------------------------------

local function is_readable_file(p)
  return p ~= nil and p ~= "" and vim.fn.filereadable(p) == 1
end

-- Collect real, existing files that could lend their name to a bare revision,
-- in priority order: alternate file, other windows in this tab, the argument
-- list, then any other loaded buffer.  Covers `:diffsplit HEAD^1` (deduce from
-- the issuing buffer) and `nvim -d file.txt HEAD^1` (deduce from the other file
-- on the command line).
local function deduce_files(cur_buf, cur_names)
  local out, seen, skip = {}, {}, {}
  for _, n in ipairs(cur_names) do
    if n and n ~= "" then
      skip[vim.fn.fnamemodify(n, ":p")] = true
    end
  end
  local function add(p)
    if not p or p == "" then
      return
    end
    local full = vim.fn.fnamemodify(p, ":p")
    if seen[full] or skip[full] then
      return
    end
    seen[full] = true
    if is_readable_file(full) then
      out[#out + 1] = full
    end
  end

  add(vim.fn.expand("#"))
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if b ~= cur_buf then
      add(vim.api.nvim_buf_get_name(b))
    end
  end
  local ok, argv = pcall(vim.fn.argv)
  if ok and type(argv) == "table" then
    for _, a in ipairs(argv) do
      add(a)
    end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= cur_buf and vim.api.nvim_buf_is_loaded(b) then
      add(vim.api.nvim_buf_get_name(b))
    end
  end
  return out
end

local function is_anchored(p)
  return p:sub(1, 1) == "/" or p:sub(1, 2) == "./" or p:sub(1, 3) == "../"
end

-- Address a real filesystem path as a git object relative to its own directory,
-- so git discovers the repo that *contains the file*, not the one at cwd.
local function object_for_file(rev, filepath)
  local abs = vim.fn.fnamemodify(filepath, ":p")
  return {
    dir = vim.fn.fnamemodify(abs, ":h"),
    object = rev .. ":./" .. vim.fn.fnamemodify(abs, ":t"),
  }
end

-- Ordered list of { dir, object } candidates for a spec, or nil.
--   * explicit rev:path -- treat the path as an ordinary (cwd-relative)
--     filename, let git discover the repo that contains it, then fall back to
--     git's repo-root-relative reading from cwd (so a root-relative path typed
--     from a subdirectory keeps working).
--   * deduced form -- borrow a filename from a real file on the command line /
--     in a sibling window and address it relative to that file's own directory.
local function locate(spec, cur_buf, cur_names)
  if spec.path then
    local cwd = vim.fn.getcwd()
    local p = spec.path
    local cands = { object_for_file(spec.rev, p) }
    if not is_anchored(p) then
      cands[#cands + 1] = { dir = cwd, object = spec.rev .. ":" .. p }
    end
    return cands, p
  end

  local files = deduce_files(cur_buf, cur_names)
  if #files == 0 then
    return nil
  end
  local file = files[1]
  return { object_for_file(spec.rev, file) }, vim.fn.fnamemodify(file, ":t")
end

--------------------------------------------------------------------------------
-- Core + entry point.
--------------------------------------------------------------------------------

-- Given a buffer and the name(s) it was opened under, try to in-fill.  Returns
-- true when the buffer was taken over, false to fall through to Neovim's
-- default new-file behaviour.
function M.try_infill(buf, cur_names)
  if not M.config.enabled then
    return false
  end
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return false
  end

  local spec
  for _, name in ipairs(cur_names) do
    spec = M.parse(name, { min_hex = M.config.min_hex })
    if spec then
      break
    end
  end
  if not spec then
    return false
  end

  local candidates, display_path = locate(spec, buf, cur_names)
  if not candidates then
    return false
  end

  -- Probe each candidate; keep the first that names a blob.  Typically one git
  -- call, at most one extra for a fallback interpretation.
  local info, object, dir, tried = nil, nil, nil, {}
  for _, c in ipairs(candidates) do
    local key = c.dir .. "\0" .. c.object
    if not tried[key] then
      tried[key] = true
      local i = probe(c.dir, c.object)
      if i and i.type == "blob" then
        info, object, dir = i, c.object, c.dir
        break
      end
    end
  end
  if not info then
    return false
  end
  if info.size > M.config.max_size then
    warn(string.format("%s is %d bytes (max %d); leaving as a new file",
      object, info.size, M.config.max_size))
    return false
  end

  local lines = read_blob(dir, info.oid, object)
  if lines == nil then
    return false
  end

  -- Populate and lock down the buffer.  nofile keeps the read-only history from
  -- being accidentally written back to a file literally named e.g. "HEAD^1".
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].swapfile = false
  vim.bo[buf].buftype = "nofile"

  -- Inherit the filetype of the file we stood in for.
  local ft = vim.filetype.match({ filename = display_path, contents = lines })
  if ft and ft ~= "" then
    vim.bo[buf].filetype = ft
  end

  -- Breadcrumb for statuslines / other tooling.
  vim.b[buf].gitrev_object = object
  return true
end

-- Autocmd entry point.  `file` is the name as typed (<afile>); we also consider
-- the possibly-absolutised buffer name so a name like "HEAD^1" that Neovim
-- expanded to "/cwd/HEAD^1" is still recognised.
function M.on_new_file(buf, file)
  local names = {}
  local function push(n)
    if n and n ~= "" then
      for _, existing in ipairs(names) do
        if existing == n then
          return
        end
      end
      names[#names + 1] = n
    end
  end
  push(file)
  local bufname = vim.api.nvim_buf_get_name(buf)
  if bufname ~= "" then
    push(vim.fn.fnamemodify(bufname, ":."))
    push(bufname)
  end

  -- Never let an error here break opening a file.
  pcall(M.try_infill, buf, names)
end

return M
