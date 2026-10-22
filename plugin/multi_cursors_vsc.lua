if vim.g.loaded_multi_cursors_vsc then
  return
end
vim.g.loaded_multi_cursors_vsc = true

local function set_hl()
  vim.api.nvim_set_hl(0, "MultiCursorsVscCursor", { default = true, reverse = true })
  vim.api.nvim_set_hl(0, "MultiCursorsVscSelection", { default = true, link = "Visual" })
end
set_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("multi_cursors_vsc_hl", { clear = true }),
  callback = set_hl,
})

vim.api.nvim_create_user_command("MultiCursorsLineEnds", function(args)
  require("multi_cursors_vsc").add_cursors_to_line_ends(args.line1, args.line2, vim.fn.line("."))
end, { range = true, desc = "Add a cursor at the end of every line in the range" })

vim.api.nvim_create_user_command("MultiCursorsMatches", function(args)
  require("multi_cursors_vsc").add_cursors_to_matches(args.line1, args.line2)
end, { range = "%", desc = "Add a cursor on every match of the last search pattern in the range" })

vim.api.nvim_create_user_command("MultiCursorsStop", function()
  require("multi_cursors_vsc").stop()
end, { desc = "Stop the active multi-cursor session" })
