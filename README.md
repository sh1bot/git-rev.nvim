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

## Diff companion

When a revision is in-filled as one side of a diff — `:diffsplit HEAD^1` or
`nvim -d file.txt HEAD^1` — it behaves like a companion to the real file:

- **focus returns to the real, editable file** (not the read-only revision), and
- the companion window is made **auxiliary**, exactly like Neovim's help window
  (`buftype=help`).

Making it auxiliary means Neovim treats the *real* file's window as the one that
matters, so quitting behaves the way you expect and no window-juggling is needed:

- a single `:q` on the real file exits (the companion doesn't keep the session
  alive), and
- if the real file has unsaved changes, `:q` aborts with `E37` — **even with
  `'hidden'` set** — and leaves both windows, instead of hiding the file and
  stranding you in the read-only revision.

The filetype/syntax and diff highlighting are unaffected by `buftype=help`. This
only applies in a diff context; a plain `:e HEAD:path` opens the revision in the
current window as an ordinary read-only buffer and is left alone. Disable the
behaviour with `diff_companion = false`.

A companion buffer is tied to its window: closing the window discards the buffer
(`bufhidden=wipe`), so re-issuing `:diffsplit HEAD^1` builds a fresh companion —
and re-runs the focus/quit setup — rather than silently reusing a lingering
buffer that would strand focus in the revision.

An alternative mechanism is available as `diff_companion = "stepaside"`: the
buffer stays an ordinary `nofile` (no help-window side effects), and instead the
companion **steps out of the way at quit time** — on `QuitPre` its window closes
before Neovim decides the quit's fate, so the real window is judged as the last
one and the same native semantics apply; if the quit turns out to have been
refused, the window is put back (same side, same size, diff re-established).
Same ergonomics, different trade-off: no `buftype=help` quirks, but a brief
window close/restore on every refused `:q`.

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
  diff_companion = true,        -- true/"help", "stepaside", or false (see above)
})
```

An in-filled buffer exposes `b:gitrev_object` (the resolved `rev:path`) for use
in a statusline or other tooling.

## Requirements

- Neovim 0.10+ (for `vim.system`)
- `git` on `PATH`

## Installation

The plugin works out of the box — no `setup()` call is required. Calling
`setup()` is only needed to override a default (see
[Configuration](#configuration)).

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{ "sh1bot/git-rev.nvim" }
```

Or, to override a default:

```lua
{
  "sh1bot/git-rev.nvim",
  opts = {
    max_size = 20 * 1024 * 1024,
  },
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use("sh1bot/git-rev.nvim")
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'sh1bot/git-rev.nvim'
```

### Native `packages` (no plugin manager)

```sh
git clone https://github.com/sh1bot/git-rev.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/git-rev.nvim
```

### Local checkout

To develop against a local clone, point your manager at the directory. For
example with lazy.nvim:

```lua
{ dir = "/path/to/git-rev.nvim" }
```

Or drop the directory into your `runtimepath` (`packpath`) — it is a standard
`plugin/` + `lua/` layout with no build step.

Whichever method you use, make sure the [requirements](#requirements) are met:
Neovim 0.10+ and `git` on your `PATH`.

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
