# gitrev.nvim

Open a git revision as if it were a file.

When you ask Neovim to edit a path that does not exist, this plugin checks
whether the name looks like a **git revision**. If it does, and it resolves to a
blob in the repository, the buffer is filled in with that blob's contents,
marked **read-only**, and given the **filetype** (and therefore syntax
highlighting) of the real file it stands in for.

```sh
nvim -d file.txt HEAD^1      # diff the working tree against file.txt @ HEAD^1
```

```vim
:diffsplit HEAD^1            " diff the current file against its parent revision
:e HEAD:src/main.c           " open src/main.c as it is at HEAD, read-only
:e abc123:                   " open the current file at commit abc123
```

## How a name is interpreted

The hard part is telling a *revision* apart from a *filename you are about to
create*, without being annoying. The rules, cheapest first (no git is run until
a name passes the syntactic gate):

1. **`<rev>:<path>`** — the standard git blob syntax. Unambiguous.
   e.g. `HEAD:Makefile`, `HEAD^1:src/main.c`, `abc123:a/b.txt`.
   An empty `<rev>` means the index/staging area: `:staged.txt`.

2. **`<rev>:`** (trailing colon) — the explicit *"this is a revision, work out
   the filename for me"* marker. This is the baseline way to force revision
   interpretation for a name that would otherwise look like a file.
   e.g. `HEAD:`, `HEAD^1:`, `v1.2.3:`.

3. **Bare `<rev>`** (no colon) — treated as a revision **only** when it is
   clearly not an ordinary filename, i.e. it is either:
   - a **hex** object id (7–64 hex digits, like git's own abbreviations), or
   - contains a character git uses in revisions but filenames rarely do:
     `^  ~  @  {  }`.

   So `HEAD^1`, `HEAD~3`, `@{u}`, `main@{yesterday}`, and `deadbeef` are picked
   up, while `HEAD`, `master`, `README`, `v1.2.3`, and `my-notes` are left
   alone. To open one of *those* as a revision, add the trailing colon
   (`HEAD:`).

In every case the revision **must actually resolve to a blob in the git repo**.
If it does not — no such object, or you are not inside a repository — the plugin
does nothing and Neovim goes on to create a normal new file with that name.

### Paths are loose about your working directory

Git's native `rev:path` resolves `path` relative to the **repo root** of git's
working directory, which is surprising: from a subdirectory the path is wrong,
and if your cwd is not in a repo at all it fails outright — even when the file
plainly lives in a repo somewhere else.

This plugin treats the path the way an ordinary filename works instead. It
resolves `path` to a real location relative to your current directory, then lets
git discover the repository that **contains that file** (not the repo, if any,
at your cwd). So all of these work:

```vim
" cwd = repo/src
:e HEAD:main.c              " finds src/main.c, no need to type src/main.c

" cwd = repo root
:e HEAD:src/main.c          " finds src/main.c

" cwd = $HOME (not a repo at all), file lives under $HOME/project (a repo)
:e HEAD:project/dir/file.txt   " discovers the repo at project/ and resolves it
```

It then falls back to git's repo-root-relative reading from cwd, so a path typed
relative to the repo root from a subdirectory keeps working too. Anchor a path
yourself with `./`, `../`, or a leading `/` to pin the meaning.

The same rule powers the deduced forms: `:diffsplit HEAD:` while editing a file
in a repo resolves against **that file's** repo, regardless of where your cwd
is.

### Deducing the filename

For forms 2 and 3 there is no path, so one is deduced from the surrounding
context, in this order:

1. the alternate file (`#`),
2. another window in the current tab page,
3. the argument list (this is what makes `nvim -d file.txt HEAD^1` work),
4. any other loaded buffer.

The first real, existing file found lends its name (addressed relative to its
own directory via git's `rev:./name` syntax, so no repo-root computation is
needed).

## Safety

- **Large files**: blobs larger than `max_size` (default 10 MiB) are skipped
  with a warning. The size is checked *before* the content is read, so a huge
  blob is never pulled into memory.
- **Huge line counts**: even within `max_size`, a blob with more than
  `max_lines` (default 500 000) lines is skipped. Newlines are counted with an
  early bail, so an over-cap blob is rejected before the line list is ever built.
- **Binary files**: a blob containing a NUL byte is treated as binary and
  skipped (git's own signal; also required because a buffer line cannot contain
  a NUL/newline).
- **Read-only**: in-filled buffers are `readonly` + `nomodifiable` and
  `buftype=nofile`, so the historical content can never be accidentally written
  back to a file literally named `HEAD^1`.

## Performance / robustness

- No git is run for names that are not revision-shaped.
- A successful in-fill costs **two** git calls: one `git cat-file --batch-check`
  metadata probe, then one blob read (done only after the size guard passes, so
  a huge blob is never read into memory). A miss costs a single probe — except
  an explicit `rev:path` that is loosely retried both cwd- and root-relative,
  which costs at most two probes.
- Every git call goes through `vim.system` with a `timeout` (default 2000 ms),
  so a slow or hung git can never freeze the editor. `vim.system` captures raw
  bytes, so binary content is detected directly (a NUL byte) with no encoding
  games, and the blob read only ever pulls a size-guarded blob into memory.

## Configuration

The plugin works with no configuration. To change defaults:

```lua
require("gitrev").setup({
  enabled   = true,
  max_size  = 10 * 1024 * 1024, -- bytes; larger blobs are skipped
  max_lines = 500000,           -- lines; blobs with more are skipped
  timeout   = 2000,             -- ms; hard ceiling on any git call
  min_hex   = 7,                -- min length for a bare hex token to be an id
  notify    = true,             -- warn when a guard skips a blob
})
```

An in-filled buffer exposes `b:gitrev_object` (the resolved `rev:path`) for use
in a statusline or other tooling.

## Requirements

- Neovim 0.10+ (for `vim.system`)
- `git` on `PATH`

## Installation

With any plugin manager, point it at this directory. For example with
lazy.nvim:

```lua
{ dir = "/path/to/git-rev.nvim" }
```

Or drop the directory into your `runtimepath` (`packpath`) — it is a standard
`plugin/` + `lua/` layout with no build step.

## Layout

```
lua/gitrev.lua        the whole plugin (parser + git layer + in-fill logic)
plugin/gitrev.lua     autoload shim: registers the BufNewFile autocmd
test/run.sh           parser unit checks + end-to-end scenarios
```

## Tests

```sh
test/run.sh   # parser unit checks and end-to-end scenarios (needs nvim + git)
```
