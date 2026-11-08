if vim.g.loaded_passaporta then
  return
end
vim.g.loaded_passaporta = 1

if vim.fn.has "nvim-0.10" == 0 then
  vim.notify("passaporta.nvim requires Neovim >= 0.10", vim.log.levels.ERROR, { title = "Passaporta" })
  return
end

vim.api.nvim_create_user_command("Passaporta", function(opts)
  require("passaporta.commands").run(opts)
end, {
  nargs = "*",
  bang = true,
  desc = "Passaporta: transfer files to remote deployments",
  complete = function(arglead, cmdline, cursorpos)
    return require("passaporta.commands").complete(arglead, cmdline, cursorpos)
  end,
})
