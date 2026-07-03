-- gitrev.nvim entry point.
--
-- Hooks the attempt to edit a non-existent file (BufNewFile) and, when the name
-- looks like a git revision, in-fills the buffer with the corresponding blob.
-- All the real work is lazy-required on first trigger so startup stays cheap.

if vim.g.loaded_gitrev then
  return
end
vim.g.loaded_gitrev = 1

-- gitrev needs vim.system (Neovim 0.10+).
if not vim.system then
  vim.notify("[gitrev] requires Neovim 0.10+ (vim.system); disabled",
    vim.log.levels.WARN)
  return
end

local group = vim.api.nvim_create_augroup("gitrev", { clear = true })

vim.api.nvim_create_autocmd("BufNewFile", {
  group = group,
  pattern = "*",
  desc = "Infill buffers named like a git revision with the blob's content",
  callback = function(args)
    require("gitrev").on_new_file(args.buf, args.file)
  end,
})
