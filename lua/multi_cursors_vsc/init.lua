local session = require("multi_cursors_vsc.session")

local api = vim.api

local M = {}

---@class multi_cursors_vsc.Keymaps
---@field line_ends string|false visual mode: a cursor at the end of every selected line (default "<M-I>", Alt/Option+Shift+i)
---@field matches string|false normal/visual mode: a cursor on every match of the last search (default "<M-L>", Alt/Option+Shift+l)

---@class multi_cursors_vsc.Config
---@field keymaps multi_cursors_vsc.Keymaps
---@field hl_group string? highlight group used for the extra cursors
---@field selection_hl_group string? highlight group used for the selected matches
---@field select_matches boolean select the matches so typing replaces them (default false: cursors after the matches)

---@type multi_cursors_vsc.Config
local defaults = {
  keymaps = {
    line_ends = "<M-I>",
    matches = "<M-L>",
  },
  select_matches = false,
}

M.config = vim.deepcopy(defaults)

---@type { mode: string|string[], lhs: string }[]
local mapped = {}

local key_ns = api.nvim_create_namespace("multi_cursors_vsc_keys")

--- The last two keys typed, oldest first, so a mapping can tell which key was
--- pressed right before it.
local recent_keys = { "", "" }

local function track_keys()
  vim.on_key(function(key, typed)
    recent_keys[1] = recent_keys[2]
    recent_keys[2] = (typed and typed ~= "") and typed or key
  end, key_ns)
end

--- Places one cursor at the end of every line in `first..last` (1-based) and
--- starts typing at `primary_lnum`.
function M.add_cursors_to_line_ends(first, last, primary_lnum)
  local specs, primary = {}, 1
  for lnum = first, last do
    local line = api.nvim_buf_get_lines(0, lnum - 1, lnum, true)[1]
    table.insert(specs, { lnum - 1, #line })
    if lnum == primary_lnum then
      primary = #specs
    end
  end
  session.start(specs, primary)
end

--- Places one cursor at the start of every line in `first..last` (1-based),
--- at the first non-blank character with `first_non_blank`, and starts typing
--- at `primary_lnum`.
function M.add_cursors_to_line_starts(first, last, primary_lnum, first_non_blank)
  local specs, primary = {}, 1
  for lnum = first, last do
    local col = 0
    if first_non_blank then
      local line = api.nvim_buf_get_lines(0, lnum - 1, lnum, true)[1]
      col = (line:find("%S") or #line + 1) - 1
    end
    table.insert(specs, { lnum - 1, col })
    if lnum == primary_lnum then
      primary = #specs
    end
  end
  session.start(specs, primary)
end

--- Places one cursor per line at display column `vcol` (1-based) of the lines
--- `first..last`, skipping lines too short to reach it.
local function add_cursors_to_column(first, last, vcol, primary_lnum)
  local specs, primary = {}, nil
  for lnum = first, last do
    local width = vim.fn.virtcol({ lnum, "$" }) - 1
    local col
    if width + 1 == vcol then
      col = #api.nvim_buf_get_lines(0, lnum - 1, lnum, true)[1]
    elseif width >= vcol then
      col = vim.fn.virtcol2col(0, lnum, vcol) - 1
    end
    if col then
      table.insert(specs, { lnum - 1, col })
      if lnum == primary_lnum then
        primary = #specs
      end
    end
  end
  if #specs == 0 then
    return
  end
  session.start(specs, primary or #specs)
end

--- The visual selection's line range, then leaves visual mode.
local function take_visual_lines()
  local v_lnum, c_lnum = vim.fn.line("v"), vim.fn.line(".")
  vim.cmd("normal! \27")
  return math.min(v_lnum, c_lnum), math.max(v_lnum, c_lnum), c_lnum
end

--- Adds cursors from the current visual selection, like VSCode's "Add Cursors
--- to Line Ends" (Alt+Shift+I). When the key pressed right before was `0`
--- (or `^`), the cursors go to the start (first non-blank) of every line
--- instead. In blockwise visual mode the cursors go to the left edge of the
--- block (or line ends after `$`).
function M.add_cursors_from_visual()
  local blockwise = vim.fn.mode() == "\22"
  local to_eol = vim.fn.winsaveview().curswant == vim.v.maxcol
  local vcol = math.min(vim.fn.virtcol("v", true)[1], vim.fn.virtcol(".", true)[1])
  local previous_key = recent_keys[1]
  local first, last, c_lnum = take_visual_lines()
  if blockwise and not to_eol then
    add_cursors_to_column(first, last, vcol, c_lnum)
  elseif not blockwise and (previous_key == "0" or previous_key == "^") then
    M.add_cursors_to_line_starts(first, last, c_lnum, previous_key == "^")
  else
    M.add_cursors_to_line_ends(first, last, c_lnum)
  end
end

--- The last search pattern, with 'smartcase' applied like "n" would.
local function search_pattern()
  local pattern = vim.fn.getreg("/")
  if pattern == "" then
    return nil
  end
  if vim.o.ignorecase and vim.o.smartcase and not pattern:find("\\[cC]") then
    -- Upper case letters that are not part of an escape like "\S".
    if pattern:gsub("\\.", ""):find("%u") then
      pattern = "\\C" .. pattern
    end
  end
  return pattern
end

--- Adds a cursor right after every match of the last search pattern in the
--- lines `first..last` (1-based, default the whole buffer), so typing cannot
--- destroy the matches by accident. With `select_matches`, the matched text
--- is selected like VSCode's "Select All Occurrences": typing replaces every
--- match, <Left> / <Right> go to the start / end of every match.
function M.add_cursors_to_matches(first, last)
  local pattern = search_pattern()
  if not pattern then
    vim.notify("multi_cursors_vsc: no previous search pattern", vim.log.levels.WARN)
    return
  end
  local buf = api.nvim_get_current_buf()
  first = first or 1
  last = last or api.nvim_buf_line_count(buf)
  local ok, matches = pcall(vim.fn.matchbufline, buf, pattern, first, last)
  if not ok then
    vim.notify("multi_cursors_vsc: " .. tostring(matches), vim.log.levels.ERROR)
    return
  end
  if #matches == 0 then
    vim.notify("multi_cursors_vsc: pattern not found: " .. vim.fn.getreg("/"), vim.log.levels.WARN)
    return
  end

  local cursor = api.nvim_win_get_cursor(0)
  local specs, primary = {}, nil
  for _, match in ipairs(matches) do
    local row = match.lnum - 1
    local e = match.byteidx + #match.text
    table.insert(specs, { row, e, sel_start = M.config.select_matches and { row, match.byteidx } or nil })
    -- The primary cursor is the match under or after the real cursor.
    if not primary and (row > cursor[1] - 1 or (row == cursor[1] - 1 and e >= cursor[2])) then
      primary = #specs
    end
  end
  session.start(specs, primary or 1)
  if M.config.select_matches then
    -- Search highlighting is drawn over the selections, hide it like :nohlsearch.
    vim.v.hlsearch = 0
  end
end

function M.add_cursors_to_matches_in_visual()
  local first, last = take_visual_lines()
  M.add_cursors_to_matches(first, last)
end

--- Stops the current multi-cursor session, if any.
function M.stop()
  session.stop()
end

function M.is_active()
  return session.is_active()
end

local function map(mode, lhs, rhs, desc)
  if lhs then
    vim.keymap.set(mode, lhs, rhs, { desc = desc })
    table.insert(mapped, { mode = mode, lhs = lhs })
  end
end

---@param opts multi_cursors_vsc.Config?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  session.hl_group = M.config.hl_group or "MultiCursorsVscCursor"
  session.selection_hl_group = M.config.selection_hl_group or "MultiCursorsVscSelection"

  track_keys()
  for _, m in ipairs(mapped) do
    pcall(vim.keymap.del, m.mode, m.lhs)
  end
  mapped = {}
  local keymaps = M.config.keymaps
  map("x", keymaps.line_ends, M.add_cursors_from_visual, "Add cursors to line ends")
  map("n", keymaps.matches, function()
    M.add_cursors_to_matches()
  end, "Add cursors to all search matches")
  map("x", keymaps.matches, M.add_cursors_to_matches_in_visual, "Add cursors to search matches in selection")
end

return M
