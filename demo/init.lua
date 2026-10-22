-- Minimal config used to record demo.gif (see demo.tape).
-- Run from anywhere: nvim -u <repo>/demo/init.lua --noplugin -i NONE -n file

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd.runtime("plugin/multi_cursors_vsc.lua")
require("multi_cursors_vsc").setup()

vim.o.termguicolors = true
vim.o.number = true
vim.o.cursorline = true
vim.o.hlsearch = true
vim.o.showmode = true
vim.o.ruler = false
vim.o.laststatus = 0
vim.o.shortmess = vim.o.shortmess .. "IF"
vim.keymap.set("i", "jj", "<Esc>")
-- VHS sends ESC and the next key separately, give Neovim time to join them
-- into one Alt key. Real terminals send them together.
vim.o.ttimeoutlen = 500

-- On-screen keys, so viewers see what is pressed.
local labels = {
  ["<M-I>"] = "⌥⇧I",
  ["<M-L>"] = "⌥⇧L",
  ["<CR>"] = "⏎",
  ["<Esc>"] = "Esc",
  ["<Space>"] = "␣",
}
local buf = vim.api.nvim_create_buf(false, true)
local win, timer = nil, assert(vim.uv.new_timer())
local shown = ""

local function hide()
  shown = ""
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
end

local function show(text)
  shown = shown == "" and text or (shown .. " " .. text)
  shown = vim.fn.strcharpart(shown, math.max(0, vim.fn.strchars(shown) - 30))
  local width = vim.fn.strdisplaywidth(shown) + 2
  vim.api.nvim_buf_set_lines(buf, 0, -1, true, { " " .. shown .. " " })
  local config = {
    relative = "editor",
    row = vim.o.lines - 4,
    col = vim.o.columns - width - 3,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 300,
  }
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, config)
  else
    win = vim.api.nvim_open_win(buf, false, config)
    vim.wo[win].winhighlight = table.concat({
      "Normal:DemoKeys",
      "NormalFloat:DemoKeys",
      "FloatBorder:DemoKeysBorder",
      "Search:DemoKeys",
      "CurSearch:DemoKeys",
      "IncSearch:DemoKeys",
    }, ",")
  end
  timer:stop()
  timer:start(1200, 0, vim.schedule_wrap(hide))
end

vim.api.nvim_set_hl(0, "DemoKeys", { fg = "#1e1e2e", bg = "#f9e2af", bold = true })
vim.api.nvim_set_hl(0, "DemoKeysBorder", { fg = "#f9e2af" })

vim.on_key(function(_, typed)
  if not typed or typed == "" then
    return
  end
  local key = vim.fn.keytrans(typed)
  vim.schedule(function()
    show(labels[key] or key)
  end)
end, vim.api.nvim_create_namespace("demo_keys"))
