-- gitrev.nvim: hook BufNewFile and in-fill revision-named buffers (lazy-required).

if vim.g.loaded_gitrev then
  return
end
vim.g.loaded_gitrev = 1

if not vim.system then -- Neovim 0.10+ required
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
