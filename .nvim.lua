print("PROJECT .nvim.lua LOADED")

vim.lsp.config("zls", {
  settings = {
    zls = {
      enable_build_on_save = true,
    },
  },
})
