-- gitrev: edit a non-existent file whose name looks like a git revision and get
-- the corresponding blob, read-only, with the filetype of the file it stands in
-- for.  Requires Neovim 0.10+ (vim.system).

local M = {}

M.config = {
  enabled = true,
  max_size = 10 * 1024 * 1024, -- bytes; larger blobs are skipped
  max_lines = 500000, -- lines; larger blobs are skipped (read aborts early)
  timeout = 2000, -- ms ceiling on any git call
  min_hex = 7, -- min length for a bare hex token to count as an object id
  notify = true, -- warn when a guard skips a blob
  diff_companion = true, -- focus/quit behaviour for `:diffsplit REV` / `-d`
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

--------------------------------------------------------------------------------
-- Name parsing (pure: no vim, no filesystem, no git).
--------------------------------------------------------------------------------

-- Punctuation git uses in revisions but filenames rarely do (colon is handled
-- separately; dots/dashes excluded as common in names).
local REV_PUNCT = "[%^~@{}]"

local function looks_hex(s, min_hex)
  min_hex = min_hex or 7
  return s:match("^%x+$") ~= nil and #s >= min_hex and #s <= 64
end

--- Parse a name into { rev, path } (path nil means "deduce it"), or nil when the
--- name is not revision-shaped.
function M.parse(name, opts)
  opts = opts or {}
  if type(name) ~= "string" or name == "" then
    return nil
  end
  -- Leave other plugins' URL-like buffers (fugitive://, oil://, ...) alone.
  if name:match("^%w[%w+.%-]*://") then
    return nil
  end

  local colon = name:find(":", 1, true)
  if colon then
    local rev = name:sub(1, colon - 1)
    local path = name:sub(colon + 1)
    -- Not a Windows drive letter ("C:\foo").
    if #rev == 1 and rev:match("%a") and path:match("^[/\\]") then
      return nil
    end
    if path == "" then
      return rev ~= "" and { rev = rev, path = nil } or nil -- trailing colon
    end
    return { rev = rev, path = path } -- rev:path (empty rev = git index)
  end

  -- No colon: a revision only when hex or carrying revision punctuation, so plain
  -- names (HEAD, master, README) stay ordinary; use "HEAD:" to force them.
  if looks_hex(name, opts.min_hex) or name:match(REV_PUNCT) then
    return { rev = name, path = nil }
  end
  return nil
end

--------------------------------------------------------------------------------
-- git layer (vim.system: argv list, no shell, raw bytes, first-class timeout).
--------------------------------------------------------------------------------

local function warn(msg)
  if M.config.notify then
    vim.notify("[gitrev] " .. msg, vim.log.levels.WARN)
  end
end

local GIT_ENV = { GIT_TERMINAL_PROMPT = "0", GIT_OPTIONAL_LOCKS = "0" }

-- { oid, type, size } for an object, or nil (missing / not a repo / timed out).
local function probe(dir, object)
  local res = vim.system({ "git", "-C", dir, "cat-file", "--batch-check" }, {
    stdin = object .. "\n",
    env = GIT_ENV,
    timeout = M.config.timeout,
  }):wait()
  if res.code ~= 0 or not res.stdout then
    return nil
  end
  -- "<oid> <type> <size>", else "<object> missing".
  local oid, otype, size = vim.trim(res.stdout):match("^(%x+)%s+(%S+)%s+(%d+)$")
  if not oid then
    return nil
  end
  return { oid = oid, type = otype, size = tonumber(size) }
end

-- Blob lines by oid, or nil on error/timeout/binary/too-many-lines.
local function read_blob(dir, oid, object)
  local res = vim.system({ "git", "-C", dir, "cat-file", "blob", oid }, {
    text = false, -- raw bytes, NULs preserved
    env = GIT_ENV,
    timeout = M.config.timeout,
  }):wait()
  if res.code ~= 0 or not res.stdout then
    return nil
  end
  local data = res.stdout

  -- A NUL is git's binary signal, and a byte a buffer line cannot hold anyway.
  if data:find("\0", 1, true) then
    warn(object .. " looks binary; leaving as a new file")
    return nil
  end

  -- Count newlines and bail past the cap before splitting, so a pathological
  -- blob never builds a giant list.
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
  if lines[#lines] == "" then -- drop the trailing-newline artifact
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

-- Real existing files that could lend their name to a bare revision, in priority
-- order: alternate file, sibling windows, argument list, other loaded buffers.
-- Covers `:diffsplit HEAD^1` and `nvim -d file HEAD^1`.
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

-- Address a file as a git object relative to its own directory, so git finds the
-- repo that contains the file, not the one at cwd.
local function object_for_file(rev, filepath)
  local abs = vim.fn.fnamemodify(filepath, ":p")
  return {
    dir = vim.fn.fnamemodify(abs, ":h"),
    object = rev .. ":./" .. vim.fn.fnamemodify(abs, ":t"),
  }
end

-- Ordered { dir, object } candidates to try, plus a display path, or nil.
local function locate(spec, cur_buf, cur_names)
  if spec.path then
    -- Explicit path: cwd-relative (via the file's own dir), then git's
    -- repo-root-relative reading as a fallback.
    local cands = { object_for_file(spec.rev, spec.path) }
    if not is_anchored(spec.path) then
      cands[#cands + 1] = { dir = vim.fn.getcwd(), object = spec.rev .. ":" .. spec.path }
    end
    return cands, spec.path
  end

  local files = deduce_files(cur_buf, cur_names)
  if #files == 0 then
    return nil
  end
  return { object_for_file(spec.rev, files[1]) }, vim.fn.fnamemodify(files[1], ":t")
end

--------------------------------------------------------------------------------
-- Core + entry point.
--------------------------------------------------------------------------------

-- Make a diff-companion buffer behave like Vim's help window.  Deferred (via
-- vim.schedule) because diff mode and sibling windows settle only after
-- `:diffsplit` / `-d` finish.
local function setup_companion(gbuf)
  -- The diff window showing our buffer (none => plain `:e REV:path`, leave be).
  -- An invalid gbuf yields no windows, so no separate validity guard is needed.
  local gwin
  for _, w in ipairs(vim.fn.win_findbuf(gbuf)) do
    if vim.wo[w].diff then
      gwin = w
      break
    end
  end
  if not gwin then
    return
  end

  -- The editable diff window beside it -- the real file.  Requiring diff here
  -- keeps a non-diff editable split from being mistaken for the partner.
  local realwin
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(gwin))) do
    if w ~= gwin and vim.wo[w].diff then
      local b = vim.api.nvim_win_get_buf(w)
      if b ~= gbuf and vim.bo[b].buftype == "" and vim.bo[b].modifiable then
        realwin = w
        break
      end
    end
  end
  if not realwin then
    return
  end

  -- buftype=help makes the companion auxiliary: it stops keeping the session
  -- alive and stops interfering with the real file's :q, so a single :q exits
  -- when clean and aborts on unsaved changes (E37) even under 'hidden' -- Vim's
  -- own mechanism, no autocmds.  Filetype/syntax and diff are unaffected.
  vim.bo[gbuf].buftype = "help"

  -- Decline focus handed to us at creation; never take it if it is elsewhere.
  if vim.api.nvim_get_current_win() == gwin then
    pcall(vim.api.nvim_set_current_win, realwin)
  end
end

-- Try to in-fill `buf`; return true if taken over, false to fall through.
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

  -- First candidate that names a blob.
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

  -- Populate and lock down.  nofile prevents an accidental :w to a file named
  -- e.g. "HEAD^1"; setup_companion may later upgrade this to buftype=help.
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].swapfile = false
  vim.bo[buf].buftype = "nofile"

  local ft = vim.filetype.match({ filename = display_path, contents = lines })
  if ft and ft ~= "" then
    vim.bo[buf].filetype = ft
  end

  vim.b[buf].gitrev_object = object -- breadcrumb for statuslines / tooling

  if M.config.diff_companion then
    vim.schedule(function()
      setup_companion(buf)
    end)
  end

  return true
end

-- Autocmd entry point.  Consider both the typed name (<afile>) and the
-- possibly-absolutised buffer name, so "HEAD^1" expanded to "/cwd/HEAD^1" still
-- matches.
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

  pcall(M.try_infill, buf, names) -- never let an error break opening a file
end

return M
