#!/usr/bin/env bash
# Test suite for gitrev.nvim: parser unit checks + end-to-end scenarios.
#
# Requires: nvim, git.  Run from anywhere:  test/run.sh
set -u

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
say() { printf '%s\n' "$*"; }
ok()   { pass=$((pass + 1)); say "  ok   - $1"; }
bad()  { fail=$((fail + 1)); say "  FAIL - $1"; }

# --- build a small repo with history -----------------------------------------
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
cd "$WORK"
git init -q -b main
mkdir -p src

# A large blob (> default 10MiB) and a binary blob.  Committed FIRST so that
# they do not sit between hello.c's two revisions -- that keeps HEAD^1 pointing
# at hello.c's v1 for the deduction tests below.
head -c 11000000 /dev/zero | tr '\0' 'x' > big.txt
printf 'ABC\0\0DEF binary\0here' > bin.dat
git add -A && git commit -qm extras

cat > src/hello.c <<'EOF'
#include <stdio.h>
int main(void) { puts("v1"); return 0; }
EOF
git add -A && git commit -qm v1
# second revision, so HEAD^1 differs from HEAD
cat > src/hello.c <<'EOF'
#include <stdio.h>
int main(void) { puts("v2"); return 0; }
EOF
git add -A && git commit -qm v2

# The plugin depends on vim.system (Neovim 0.10+).  This test box may only have
# 0.9.x, so provide a faithful, test-only polyfill: raw bytes (NULs preserved
# via jobstart's reversible NUL<->NL swap) and a vim.wait-based timeout.  Only
# the subset gitrev uses is implemented.  Loaded before the plugin so its
# vim.system guard passes and the real code path is exercised.
SHIM="$WORK/shim.lua"
cat > "$SHIM" <<'LUA'
if not vim.system then
  vim.system = function(cmd, opts)
    opts = opts or {}
    local chunks, code, done = {}, nil, false
    local job = vim.fn.jobstart(cmd, {
      stdout_buffered = true,
      on_stdout = function(_, d)
        if d then
          for i = 1, #d do d[i] = d[i]:gsub("\n", "\0") end
          chunks[#chunks + 1] = table.concat(d, "\n")
        end
      end,
      on_exit = function(_, c) code, done = c, true end,
      env = opts.env,
    })
    if opts.stdin then
      vim.fn.chansend(job, opts.stdin)
      vim.fn.chanclose(job, "stdin")
    end
    return {
      wait = function(_, t)
        local ok = vim.wait(t or opts.timeout or 10000, function() return done end, 10)
        if not ok then
          pcall(vim.fn.jobstop, job)
          return { code = 124, stdout = table.concat(chunks, "") }
        end
        return { code = code, stdout = table.concat(chunks, "") }
      end,
    }
  end
end
LUA

MIN_INIT="$WORK/init.lua"
cat > "$MIN_INIT" <<EOF
dofile("$SHIM")
vim.opt.runtimepath:prepend("$PLUGIN_ROOT")
vim.opt.swapfile = false
EOF

# run nvim headless, print a probe line, capture it
# usage: run_nvim <lua-after-load> -- <nvim args...>
run_nvim() {
  local lua="$1"; shift
  nvim --headless -u "$MIN_INIT" "$@" \
    +"lua $lua" +"qa!" 2>&1
}

# ===========================================================================
# Part 1: parser unit checks (M.parse -- pure, no git/filesystem).
# Runs entirely inside one nvim; prints "PARSE-OK n" or "PARSE-FAIL ...".
# ===========================================================================
cat > "$WORK/parse_spec.lua" <<'LUA'
local g = require("gitrev")
local n, bad = 0, 0
local function eq(a, b) return a == b end
local function want(name, w)
  n = n + 1
  local s = g.parse(name)
  local okk
  if w == nil then
    okk = (s == nil)
  else
    okk = s ~= nil and eq(s.rev, w.rev) and eq(s.path, w.path)
  end
  if not okk then bad = bad + 1; io.write("PARSE-FAIL " .. name .. "\n") end
end
-- bare revisions with punctuation / hex -> deduce filename (path = nil)
want("HEAD^1",   { rev = "HEAD^1",   path = nil })
want("HEAD~3",   { rev = "HEAD~3",   path = nil })
want("@{u}",     { rev = "@{u}",     path = nil })
want("deadbeef", { rev = "deadbeef", path = nil })
want("a1b2c3d",  { rev = "a1b2c3d",  path = nil })
-- trailing colon -> deduce filename (path = nil)
want("HEAD:",   { rev = "HEAD",   path = nil })
want("HEAD^1:", { rev = "HEAD^1", path = nil })
want("v1.2.3:", { rev = "v1.2.3", path = nil })
-- explicit rev:path
want("HEAD:src/main.c", { rev = "HEAD", path = "src/main.c" })
want(":staged.txt",     { rev = "",     path = "staged.txt" })
-- names that must NOT be hijacked
for _, s in ipairs({ "HEAD", "master", "README", "v1.2.3", "my-notes",
  "notes.txt", "Makefile", "dead", "fugitive:///x", "term://zsh",
  "C:/Users/me/f.txt", "D:\\a\\b.c" }) do
  want(s, nil)
end
io.write("PARSE-OK " .. (n - bad) .. "/" .. n .. "\n")
LUA
pout="$(nvim --headless -u "$MIN_INIT" +"luafile $WORK/parse_spec.lua" +"qa!" 2>&1)"
case "$pout" in
  *"PARSE-FAIL"*) bad "parser: $pout" ;;
  *"PARSE-OK "*) ok "parser unit checks (${pout##*PARSE-OK })" ;;
  *) bad "parser produced no result :: $pout" ;;
esac

# ===========================================================================
# Part 2: end-to-end scenarios against a real repo.
# ===========================================================================
# 1. diff-on-the-commandline: nvim -d src/hello.c HEAD^1  (deduced filename)
out="$(cd "$WORK" && run_nvim \
  'local b=vim.fn.bufnr("HEAD^1"); io.write("RO="..tostring(vim.bo[b].readonly)..";FT="..vim.bo[b].filetype..";BT="..vim.bo[b].buftype..";TXT="..table.concat(vim.api.nvim_buf_get_lines(b,0,-1,false),"\n"))' \
  -d src/hello.c 'HEAD^1')"
case "$out" in
  *"RO=true"*"FT=c"*"BT=nofile"*'puts("v1")'*) ok "nvim -d deduces filename, v1 content, RO, ft=c" ;;
  *) bad "nvim -d HEAD^1 :: $out" ;;
esac

# 2. :diffsplit HEAD^1 from an open file (deduce from issuing buffer)
out="$(cd "$WORK" && run_nvim \
  'vim.cmd("diffsplit HEAD^1"); local b=vim.fn.bufnr("HEAD^1"); io.write("RO="..tostring(vim.bo[b].readonly)..";TXT="..table.concat(vim.api.nvim_buf_get_lines(b,0,-1,false),"\n"))' \
  src/hello.c)"
case "$out" in
  *"RO=true"*'puts("v1")'*) ok ":diffsplit HEAD^1 deduces from current buffer" ;;
  *) bad ":diffsplit HEAD^1 :: $out" ;;
esac

# 3. explicit rev:path form
out="$(cd "$WORK" && run_nvim \
  'local b=vim.fn.bufnr("HEAD:src/hello.c"); io.write("TXT="..table.concat(vim.api.nvim_buf_get_lines(b,0,-1,false),"\n"))' \
  'HEAD:src/hello.c')"
case "$out" in
  *'puts("v2")'*) ok "explicit HEAD:src/hello.c loads current version" ;;
  *) bad "HEAD:src/hello.c :: $out" ;;
esac

# 4. trailing-colon explicit deduce form
out="$(cd "$WORK" && run_nvim \
  'vim.cmd("diffsplit HEAD^1:"); local b=vim.fn.bufnr("HEAD^1:"); io.write("TXT="..table.concat(vim.api.nvim_buf_get_lines(b,0,-1,false),"\n").."|BT="..vim.bo[b].buftype)' \
  src/hello.c)"
case "$out" in
  *'puts("v1")'*"BT=nofile"*) ok "trailing-colon HEAD^1: deduces filename" ;;
  *) bad "HEAD^1: :: $out" ;;
esac

# 5. plain non-revision filename must be a normal (writable, empty) new file
out="$(cd "$WORK" && run_nvim \
  'local b=vim.fn.bufnr("notes.txt"); io.write("MOD="..tostring(vim.bo[b].modifiable)..";BT="..vim.bo[b].buftype..";N="..#vim.api.nvim_buf_get_lines(b,0,-1,false))' \
  'notes.txt')"
case "$out" in
  *"MOD=true"*"BT="*";N=1"*) ok "plain notes.txt stays a normal new file" ;;
  *) bad "notes.txt :: $out" ;;
esac

# 6. bare 'HEAD' (no punctuation, not hex) must NOT be hijacked
out="$(cd "$WORK" && run_nvim \
  'local b=vim.fn.bufnr("HEAD"); io.write("MOD="..tostring(vim.bo[b].modifiable)..";N="..#vim.api.nvim_buf_get_lines(b,0,-1,false))' \
  'HEAD')"
case "$out" in
  *"MOD=true"*";N=1"*) ok "bare HEAD is left as an ordinary new file" ;;
  *) bad "bare HEAD :: $out" ;;
esac

# 7. revision that does not resolve -> fall through to new file
out="$(cd "$WORK" && run_nvim \
  'local b=vim.fn.bufnr("HEAD~99"); io.write("MOD="..tostring(vim.bo[b].modifiable))' \
  src/hello.c 'HEAD~99')"
case "$out" in
  *"MOD=true"*) ok "unresolvable HEAD~99 falls through to a new file" ;;
  *) bad "HEAD~99 :: $out" ;;
esac

# 8. large blob guard: HEAD:big.txt should be skipped (left modifiable/empty)
out="$(cd "$WORK" && run_nvim \
  'local b=vim.fn.bufnr("HEAD:big.txt"); io.write("MOD="..tostring(vim.bo[b].modifiable)..";N="..#vim.api.nvim_buf_get_lines(b,0,-1,false))' \
  'HEAD:big.txt' 2>/dev/null)"
case "$out" in
  *"MOD=true"*";N=1"*) ok "large blob is guarded (not loaded)" ;;
  *) bad "large blob guard :: $out" ;;
esac

# 9. binary blob guard: HEAD:bin.dat should be skipped
out="$(cd "$WORK" && run_nvim \
  'local b=vim.fn.bufnr("HEAD:bin.dat"); io.write("MOD="..tostring(vim.bo[b].modifiable)..";N="..#vim.api.nvim_buf_get_lines(b,0,-1,false))' \
  'HEAD:bin.dat' 2>/dev/null)"
case "$out" in
  *"MOD=true"*";N=1"*) ok "binary blob is guarded (not loaded)" ;;
  *) bad "binary blob guard :: $out" ;;
esac

# 10. outside any git repo -> fall through
NOGIT="$(mktemp -d)"
out="$(cd "$NOGIT" && run_nvim \
  'local b=vim.fn.bufnr("HEAD^1"); io.write("MOD="..tostring(vim.bo[b].modifiable))' \
  somefile.txt 'HEAD^1')"
rm -rf "$NOGIT"
case "$out" in
  *"MOD=true"*) ok "outside a git repo falls through" ;;
  *) bad "outside repo :: $out" ;;
esac

# 11. loose subdir: cwd inside src/, non-qualified path HEAD:hello.c resolves
out="$(cd "$WORK/src" && run_nvim \
  'local b=vim.fn.bufnr("HEAD:hello.c"); io.write("OBJ="..tostring(vim.b[b].gitrev_object)..";TXT="..table.concat(vim.api.nvim_buf_get_lines(b,0,-1,false),"\n"))' \
  'HEAD:hello.c')"
case "$out" in
  *'puts("v2")'*) ok "loose: HEAD:hello.c resolves from subdirectory" ;;
  *) bad "subdir HEAD:hello.c :: $out" ;;
esac

# 12. regression: fully-qualified path from repo root still resolves
out="$(cd "$WORK" && run_nvim \
  'local b=vim.fn.bufnr("HEAD:src/hello.c"); io.write("TXT="..table.concat(vim.api.nvim_buf_get_lines(b,0,-1,false),"\n"))' \
  'HEAD:src/hello.c')"
case "$out" in
  *'puts("v2")'*) ok "root-relative HEAD:src/hello.c still resolves from repo root" ;;
  *) bad "root-relative regression :: $out" ;;
esac

# 13. loose subdir with an explicit subpath: from src/, HEAD:hello.c vs a
#     deeper tree -- ensure a nested cwd-relative path resolves too.
mkdir -p "$WORK/src/deep" && (cd "$WORK" && cat > src/deep/z.txt <<< 'zebra' && git add -A && git commit -qm z >/dev/null)
out="$(cd "$WORK/src" && run_nvim \
  'local b=vim.fn.bufnr("HEAD:deep/z.txt"); io.write("TXT="..table.concat(vim.api.nvim_buf_get_lines(b,0,-1,false),"\n"))' \
  'HEAD:deep/z.txt')"
case "$out" in
  *'zebra'*) ok "loose: HEAD:deep/z.txt resolves relative to subdirectory cwd" ;;
  *) bad "subdir nested path :: $out" ;;
esac

# 14. explicit rev:path issued from OUTSIDE any repo: the repo must be
#     discovered from the file's own location, not from cwd.
OUTER="$(mktemp -d)"            # not a git repo
mkdir -p "$OUTER/proj/sub"
( cd "$OUTER/proj" && git init -q -b main \
    && printf 'from-HEAD\n' > sub/f.txt && git add -A && git commit -qm one >/dev/null \
    && printf 'working\n' > sub/f.txt )   # working tree differs from HEAD
out="$(cd "$OUTER" && run_nvim \
  'local b=vim.fn.bufnr("HEAD:proj/sub/f.txt"); io.write("OBJ="..tostring(vim.b[b].gitrev_object)..";RO="..tostring(vim.bo[b].readonly)..";TXT="..table.concat(vim.api.nvim_buf_get_lines(b,0,-1,false),"\n"))' \
  'HEAD:proj/sub/f.txt')"
rm -rf "$OUTER"
case "$out" in
  *"RO=true"*'from-HEAD'*) ok "explicit rev:path discovers repo from file location, not cwd" ;;
  *) bad "explicit rev:path from outside repo :: $out" ;;
esac

# 15. exact line reconstruction: trailing newline must not add a blank line,
#     and a blob without a trailing newline must keep all its content.
( cd "$WORK" && printf 'L1\nL2\nL3\n' > withnl.txt && printf 'only-line-no-nl' > nonl.txt \
    && git add -A && git commit -qm lines >/dev/null )
out="$(cd "$WORK" && run_nvim \
  'vim.cmd("edit HEAD:withnl.txt"); local la=vim.api.nvim_buf_get_lines(0,0,-1,false);
   vim.cmd("edit HEAD:nonl.txt");  local lb=vim.api.nvim_buf_get_lines(0,0,-1,false);
   io.write("A="..#la.."/"..table.concat(la,",")..";B="..#lb.."/"..table.concat(lb,","))')"
case "$out" in
  *"A=3/L1,L2,L3;B=1/only-line-no-nl"*) ok "exact lines: trailing NL trimmed, missing NL preserved" ;;
  *) bad "line reconstruction :: $out" ;;
esac

# 16. max_lines guard: a blob with more lines than the configured cap is
#     skipped (streamed abort), leaving a normal new file.
( cd "$WORK" && seq 1 5000 > many.txt && git add -A && git commit -qm many >/dev/null )
ML_INIT="$WORK/init_ml.lua"
cat > "$ML_INIT" <<EOF
dofile("$SHIM")
vim.opt.runtimepath:prepend("$PLUGIN_ROOT")
vim.opt.swapfile = false
require('gitrev').setup({ max_lines = 100 })
EOF
out="$(cd "$WORK" && nvim --headless -u "$ML_INIT" 'HEAD:many.txt' \
  +"lua local b=vim.fn.bufnr('HEAD:many.txt'); io.write('mod='..tostring(vim.bo[b].modifiable)..' obj='..tostring(vim.b[b].gitrev_object))" \
  +'qa!' 2>&1)"
case "$out" in
  *"mod=true"*"obj=nil"*) ok "max_lines guard skips a blob over the cap" ;;
  *) bad "max_lines guard :: $out" ;;
esac

# 17. diff companion: focus returns to the real file after :diffsplit.
out="$(cd "$WORK" && run_nvim \
  'vim.cmd("diffsplit HEAD^1"); vim.wait(200); local cb=vim.api.nvim_get_current_buf();
   io.write("focus_gitrev="..tostring(vim.b[cb].gitrev_object~=nil)..";name="..vim.fn.fnamemodify(vim.api.nvim_buf_get_name(cb),":t"))' \
  src/hello.c)"
case "$out" in
  *"focus_gitrev=false"*"name=hello.c"*) ok "diff companion: focus returns to the real file" ;;
  *) bad "companion focus :: $out" ;;
esac

# 18. diff companion: a single :quit on the real file exits (companion closes).
rm -f "$WORK/survived"
( cd "$WORK" && nvim --headless -u "$MIN_INIT" src/hello.c \
    +'lua vim.cmd("diffsplit HEAD^1"); vim.wait(200)' \
    +'quit' \
    +"call writefile(['x'], '$WORK/survived')" \
    +'qa!' >/dev/null 2>&1 )
if [ -f "$WORK/survived" ]; then
  bad "companion auto-close: nvim survived a single :quit"
else
  ok "diff companion: single :quit exits (companion auto-closed)"
fi

# 19. plain :e REV:path is NOT a companion (focus stays, no extra windows).
out="$(cd "$WORK" && run_nvim \
  'vim.cmd("edit HEAD:src/hello.c"); vim.wait(200);
   local cb=vim.api.nvim_get_current_buf();
   io.write("on_gitrev="..tostring(vim.b[cb].gitrev_object~=nil)..";wins="..#vim.api.nvim_list_wins())')"
case "$out" in
  *"on_gitrev=true"*"wins=1"*) ok "plain :e is not treated as a diff companion" ;;
  *) bad "plain :e companion leak :: $out" ;;
esac

# 20. relationship broken (:diffoff!) -> auto-close backs off, companion survives
#     a :quit on the real file (so nvim does NOT exit on a single :quit).
rm -f "$WORK/survived20"
( cd "$WORK" && nvim --headless -u "$MIN_INIT" src/hello.c \
    +'lua vim.cmd("diffsplit HEAD^1"); vim.wait(200)' \
    +'diffoff!' \
    +'quit' \
    +"call writefile(['x'], '$WORK/survived20')" \
    +'qa!' >/dev/null 2>&1 )
if [ -f "$WORK/survived20" ]; then
  ok "companion backs off when the diff relationship is broken"
else
  bad "companion still force-closed after :diffoff! (should back off)"
fi

# 21. unsaved real file: a quit that Vim would abort/confirm must NOT close the
#     companion.  Fire QuitPre directly (headless :q does not enforce E37) and
#     assert the handler backs off while the real buffer is modified, but acts
#     once it is unmodified.
out="$(cd "$WORK" && run_nvim \
  'vim.cmd("edit src/hello.c"); vim.cmd("diffsplit HEAD^1"); vim.wait(200);
   vim.api.nvim_buf_set_lines(0,0,0,false,{"// dirty"});
   vim.cmd("doautocmd QuitPre"); local dirty=#vim.api.nvim_list_wins();
   vim.bo.modified=false;
   vim.cmd("doautocmd QuitPre"); local clean=#vim.api.nvim_list_wins();
   io.write("dirty_wins="..dirty..";clean_wins="..clean)')"
case "$out" in
  *"dirty_wins=2"*"clean_wins=1"*) ok "unsaved real file: companion kept until the real file is saved" ;;
  *) bad "unsaved-real companion :: $out" ;;
esac

say ""
say "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
