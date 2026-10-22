-- A multi-cursor insert session.
--
-- The real cursor is the "primary" cursor, every other cursor is a
-- "secondary" one. Each cursor has an anchor position. Every change the user
-- makes around the primary anchor is recorded (through `on_bytes`) as an edit
-- relative to that anchor: "delete N characters at offset K, insert TEXT".
-- On the next safe point (TextChangedI, CursorMovedI, InsertLeave, ...) those
-- edits are replayed at every secondary anchor, and plain cursor movements of
-- the primary cursor are applied to the secondary anchors.
--
-- A session can start with every cursor at the end of a selection (e.g. a
-- search match). Like in VSCode, the first edit then replaces every
-- selection, while a first <Left>/<Right> collapses them.
--
-- Positions are plain values adjusted on every buffer change, so they behave
-- exactly the same for the primary and the secondary cursors.

local api = vim.api

local M = {}

local cursor_ns = api.nvim_create_namespace("multi_cursors_vsc_cursors")
local augroup = api.nvim_create_augroup("multi_cursors_vsc", { clear = true })

M.hl_group = "MultiCursorsVscCursor"
M.selection_hl_group = "MultiCursorsVscSelection"

---@alias multi_cursors_vsc.Pos { [1]: integer, [2]: integer } 0-based row, byte column

---@class multi_cursors_vsc.Cursor
---@field pos multi_cursors_vsc.Pos anchor, pushed by text inserted at it
---@field sel? { s: multi_cursors_vsc.Pos, e: multi_cursors_vsc.Pos } selected text

---@class multi_cursors_vsc.Edit
---@field offset integer characters from the anchor to the edit start
---@field deleted integer number of deleted characters
---@field lines string[] inserted text
---@field in_selection boolean deletion inside the pending primary selection

---@class multi_cursors_vsc.Session
---@field buf integer
---@field win integer
---@field primary multi_cursors_vsc.Cursor
---@field secondaries multi_cursors_vsc.Cursor[]
---@field pending boolean cursors still have their initial selections
---@field shadow string[] buffer lines as of the last change
---@field edits multi_cursors_vsc.Edit[] primary edits not replayed yet
---@field replaying boolean
---@field diverged boolean an edit happened that cannot be mirrored
---@field maps table<string, table|false> session keys, with the buffer-local mapping each one shadows

---@type multi_cursors_vsc.Session?
local active = nil

local function cmp(a, b)
  if a[1] ~= b[1] then
    return a[1] < b[1] and -1 or 1
  end
  if a[2] ~= b[2] then
    return a[2] < b[2] and -1 or 1
  end
  return 0
end

local function get_line(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, true)[1]
end

--- Text between two positions of a list of lines, joined with "\n".
local function text_between(lines, from, to)
  if from[1] == to[1] then
    return lines[from[1] + 1]:sub(from[2] + 1, to[2])
  end
  local parts = { lines[from[1] + 1]:sub(from[2] + 1) }
  for row = from[1] + 1, to[1] - 1 do
    parts[#parts + 1] = lines[row + 1]
  end
  parts[#parts + 1] = lines[to[1] + 1]:sub(1, to[2])
  return table.concat(parts, "\n")
end

local function nchars(s)
  return vim.fn.strchars(s)
end

--- Moves a position by `n` characters (negative goes backwards), crossing
--- line boundaries like a character-wise cursor would.
local function offset_pos(buf, pos, n)
  local row, col = pos[1], pos[2]
  local last_row = api.nvim_buf_line_count(buf) - 1
  local line = get_line(buf, row)
  while n < 0 do
    if col == 0 then
      if row == 0 then
        break
      end
      row = row - 1
      line = get_line(buf, row)
      col = #line
    else
      col = col - 1 + vim.str_utf_start(line, col)
    end
    n = n + 1
  end
  while n > 0 do
    if col >= #line then
      if row == last_row then
        break
      end
      row = row + 1
      line = get_line(buf, row)
      col = 0
    else
      col = col + 1 + vim.str_utf_end(line, col + 1)
    end
    n = n - 1
  end
  return { row, col }
end

--- Signed number of characters from `from` to `to`.
local function distance(lines, from, to)
  local c = cmp(from, to)
  if c == 0 then
    return 0
  elseif c < 0 then
    return nchars(text_between(lines, from, to))
  end
  return -nchars(text_between(lines, to, from))
end

--- Adjusts a position for a change replacing `start..old_end` with text
--- ending at `new_end`. Positions touching the changed range end up after the
--- new text, or before it with `left_gravity`.
local function adjust(pos, start, old_end, new_end, left_gravity)
  if cmp(pos, start) < 0 or (left_gravity and cmp(pos, start) == 0) then
    return pos
  end
  if cmp(pos, old_end) <= 0 then
    return left_gravity and { start[1], start[2] } or { new_end[1], new_end[2] }
  end
  if pos[1] == old_end[1] then
    return { new_end[1], new_end[2] + pos[2] - old_end[2] }
  end
  return { pos[1] + new_end[1] - old_end[1], pos[2] }
end

local function each_cursor(sess, fn)
  fn(sess.primary)
  for _, cursor in ipairs(sess.secondaries) do
    fn(cursor)
  end
end

--- Whether a change is a pure deletion inside the pending primary selection.
local function deletes_in_selection(sess, start, old_end, new_end)
  local sel = sess.primary.sel
  return sess.pending
    and sel ~= nil
    and cmp(start, new_end) == 0
    and cmp(sel.s, start) <= 0
    and cmp(old_end, sel.e) <= 0
end

local function on_bytes(sess, sr, sc, oer, oec, ner, nec)
  local buf = sess.buf
  local start = { sr, sc }
  local old_end = { sr + oer, oer == 0 and sc + oec or oec }
  local new_end = { sr + ner, ner == 0 and sc + nec or nec }
  local new_lines = api.nvim_buf_get_text(buf, sr, sc, new_end[1], new_end[2], {})

  if not sess.replaying and not sess.diverged then
    local anchor = sess.primary.pos
    -- Only changes at the anchor's line are mirrored, plus deletions of a
    -- line break right before or after it (<BS> at column 0, <Del> at EOL).
    if sr == anchor[1] or cmp(old_end, anchor) == 0 then
      table.insert(sess.edits, {
        offset = distance(sess.shadow, anchor, start),
        deleted = nchars(text_between(sess.shadow, start, old_end)),
        lines = new_lines,
        in_selection = deletes_in_selection(sess, start, old_end, new_end),
      })
    else
      sess.diverged = true
    end
  end

  -- Keep the shadow copy in sync with the buffer.
  local first = sess.shadow[sr + 1] or ""
  local last = sess.shadow[old_end[1] + 1] or ""
  local replacement = vim.deepcopy(new_lines)
  replacement[1] = first:sub(1, sc) .. replacement[1]
  replacement[#replacement] = replacement[#replacement] .. last:sub(old_end[2] + 1)
  local shadow = sess.shadow
  local spliced = {}
  for i = 1, sr do
    spliced[i] = shadow[i]
  end
  vim.list_extend(spliced, replacement)
  for i = old_end[1] + 2, #shadow do
    spliced[#spliced + 1] = shadow[i]
  end
  sess.shadow = spliced

  each_cursor(sess, function(cursor)
    cursor.pos = adjust(cursor.pos, start, old_end, new_end)
    if cursor.sel then
      cursor.sel.s = adjust(cursor.sel.s, start, old_end, new_end)
      cursor.sel.e = adjust(cursor.sel.e, start, old_end, new_end, true)
    end
  end)
end

--- Maps an insert mode key in the session buffer, shadowing (and later
--- restoring) any buffer-local mapping of the user.
local function map_key(sess, lhs, fn, desc)
  if sess.maps[lhs] == nil then
    local existing = vim.fn.maparg(lhs, "i", false, true)
    sess.maps[lhs] = existing.buffer == 1 and existing or false
  end
  vim.keymap.set("i", lhs, fn, { buffer = sess.buf, desc = desc })
end

local function unmap_key(sess, lhs)
  local saved = sess.maps[lhs]
  if saved == nil then
    return
  end
  sess.maps[lhs] = nil
  if not api.nvim_buf_is_valid(sess.buf) then
    return
  end
  pcall(vim.keymap.del, "i", lhs, { buffer = sess.buf })
  if saved then
    api.nvim_buf_call(sess.buf, function()
      vim.fn.mapset("i", false, saved)
    end)
  end
end

local function clear_selections(sess)
  if not sess.pending then
    return
  end
  sess.pending = false
  each_cursor(sess, function(cursor)
    cursor.sel = nil
  end)
  unmap_key(sess, "<Left>")
  unmap_key(sess, "<Right>")
end

--- The first edit of a session started with selections replaces them all.
local function replace_selections(sess)
  -- Deleting inside the selection (<BS>, <C-w>) only means "delete it".
  sess.edits = vim.tbl_filter(function(edit)
    return not edit.in_selection
  end, sess.edits)
  sess.replaying = true
  each_cursor(sess, function(cursor)
    local sel = cursor.sel
    if sel and cmp(sel.s, sel.e) < 0 then
      api.nvim_buf_set_text(sess.buf, sel.s[1], sel.s[2], sel.e[1], sel.e[2], {})
    end
  end)
  sess.replaying = false
  clear_selections(sess)
end

--- Replays pending primary edits at every secondary cursor.
local function replay(sess)
  if sess.pending and #sess.edits > 0 then
    replace_selections(sess)
  end
  local edits = sess.edits
  if #edits == 0 then
    return
  end
  sess.edits = {}
  local buf = sess.buf
  sess.replaying = true
  for _, cursor in ipairs(sess.secondaries) do
    for _, edit in ipairs(edits) do
      local from = offset_pos(buf, cursor.pos, edit.offset)
      local to = offset_pos(buf, from, edit.deleted)
      api.nvim_buf_set_text(buf, from[1], from[2], to[1], to[2], edit.lines)
    end
  end
  sess.replaying = false
end

local function set_primary(sess, pos)
  sess.primary.pos = pos
  api.nvim_win_set_cursor(sess.win, { pos[1] + 1, pos[2] })
end

--- Merges cursors that ended up at the same position.
local function dedupe(sess)
  local seen = { [sess.primary.pos[1] .. ":" .. sess.primary.pos[2]] = true }
  sess.secondaries = vim.tbl_filter(function(cursor)
    local key = cursor.pos[1] .. ":" .. cursor.pos[2]
    if seen[key] then
      return false
    end
    seen[key] = true
    return true
  end, sess.secondaries)
end

--- Applies plain movements of the real cursor to the secondary cursors.
--- Returns false when the movement cannot be mirrored.
local function follow_cursor(sess)
  local pos = api.nvim_win_get_cursor(sess.win)
  local cursor = { pos[1] - 1, pos[2] }
  if cmp(cursor, sess.primary.pos) == 0 then
    return true
  end
  if cursor[1] ~= sess.primary.pos[1] then
    return false
  end
  -- Any other movement drops the selections, like in VSCode.
  clear_selections(sess)
  local delta = distance(sess.shadow, sess.primary.pos, cursor)
  for _, c in ipairs(sess.secondaries) do
    c.pos = offset_pos(sess.buf, c.pos, delta)
  end
  sess.primary.pos = cursor
  dedupe(sess)
  return true
end

local function render(sess)
  local buf = sess.buf
  api.nvim_buf_clear_namespace(buf, cursor_ns, 0, -1)
  each_cursor(sess, function(cursor)
    local sel = cursor.sel
    if sel and cmp(sel.s, sel.e) < 0 then
      api.nvim_buf_set_extmark(buf, cursor_ns, sel.s[1], sel.s[2], {
        end_row = sel.e[1],
        end_col = sel.e[2],
        hl_group = M.selection_hl_group,
        priority = 9999,
      })
    end
  end)
  for _, cursor in ipairs(sess.secondaries) do
    local row, col = cursor.pos[1], cursor.pos[2]
    local line = get_line(buf, row)
    if col < #line then
      api.nvim_buf_set_extmark(buf, cursor_ns, row, col, {
        end_col = col + 1 + vim.str_utf_end(line, col + 1),
        hl_group = M.hl_group,
        priority = 10000,
      })
    else
      api.nvim_buf_set_extmark(buf, cursor_ns, row, col, {
        virt_text = { { " ", M.hl_group } },
        virt_text_pos = "overlay",
        priority = 10000,
      })
    end
  end
end

function M.stop()
  local sess = active
  if not sess then
    return
  end
  active = nil
  api.nvim_clear_autocmds({ group = augroup })
  if api.nvim_buf_is_valid(sess.buf) then
    api.nvim_buf_clear_namespace(sess.buf, cursor_ns, 0, -1)
  end
  for lhs in pairs(sess.maps) do
    unmap_key(sess, lhs)
  end
end

function M.is_active()
  return active ~= nil
end

--- Brings the secondary cursors up to date with the primary one.
local function update(sess)
  if active ~= sess then
    return
  end
  if api.nvim_get_current_buf() ~= sess.buf or api.nvim_get_current_win() ~= sess.win then
    M.stop()
    return
  end
  replay(sess)
  if sess.diverged or not follow_cursor(sess) then
    M.stop()
    return
  end
  render(sess)
end

--- Replays pending edits before a session key acts. Returns false when the
--- session is over.
local function prepare_key(sess)
  if active ~= sess then
    return false
  end
  replay(sess)
  if sess.diverged then
    M.stop()
    return false
  end
  return true
end

--- <Left> / <Right> while the initial selections are active: collapse every
--- selection to its start / end, like VSCode.
local function collapse(sess, to_start)
  if not prepare_key(sess) then
    return
  end
  if not sess.pending then
    -- Already replaced by an edit typed earlier: act as the plain key.
    local row, col = sess.primary.pos[1], sess.primary.pos[2]
    local line = get_line(sess.buf, row)
    if to_start and col > 0 then
      col = col - 1 + vim.str_utf_start(line, col)
    elseif not to_start and col < #line then
      col = col + 1 + vim.str_utf_end(line, col + 1)
    end
    api.nvim_win_set_cursor(sess.win, { row + 1, col })
    return
  end
  if to_start then
    each_cursor(sess, function(cursor)
      cursor.pos = cursor.sel.s
    end)
  end
  clear_selections(sess)
  set_primary(sess, sess.primary.pos)
  render(sess)
end

--- Moves every cursor to a column of its own line, e.g. <Home> and <End>.
---@param target fun(line: string, col: integer): integer
local function move_each(sess, target)
  if not prepare_key(sess) then
    return
  end
  clear_selections(sess)
  each_cursor(sess, function(cursor)
    local row, col = cursor.pos[1], cursor.pos[2]
    cursor.pos = { row, target(get_line(sess.buf, row), col) }
  end)
  set_primary(sess, sess.primary.pos)
  dedupe(sess)
  render(sess)
end

local function home(line, col)
  local first_non_blank = (line:find("%S") or #line + 1) - 1
  return col == first_non_blank and 0 or first_non_blank
end

local function line_end(line)
  return #line
end

---@class multi_cursors_vsc.CursorSpec
---@field [1] integer 0-based row
---@field [2] integer byte column
---@field sel_start? multi_cursors_vsc.Pos start of the text selected up to the cursor

--- Starts a session and enters insert mode at the primary position.
---@param specs multi_cursors_vsc.CursorSpec[]
---@param primary integer index of the primary cursor in `specs`
function M.start(specs, primary)
  M.stop()
  local buf = api.nvim_get_current_buf()
  local win = api.nvim_get_current_win()
  ---@type multi_cursors_vsc.Session
  local sess = {
    buf = buf,
    win = win,
    secondaries = {},
    pending = false,
    shadow = api.nvim_buf_get_lines(buf, 0, -1, true),
    edits = {},
    replaying = false,
    diverged = false,
    maps = {},
  }
  for i, spec in ipairs(specs) do
    local cursor = { pos = { spec[1], spec[2] } }
    if spec.sel_start and cmp(spec.sel_start, cursor.pos) < 0 then
      cursor.sel = { s = { spec.sel_start[1], spec.sel_start[2] }, e = { spec[1], spec[2] } }
      sess.pending = true
    end
    if i == primary then
      sess.primary = cursor
    else
      table.insert(sess.secondaries, cursor)
    end
  end
  if sess.pending then
    -- Every cursor needs a selection for <Left> to collapse consistently.
    each_cursor(sess, function(cursor)
      cursor.sel = cursor.sel or { s = cursor.pos, e = cursor.pos }
    end)
  end
  active = sess

  api.nvim_buf_attach(buf, false, {
    on_bytes = function(_, _, _, sr, sc, _, oer, oec, _, ner, nec)
      if active ~= sess then
        return true
      end
      on_bytes(sess, sr, sc, oer, oec, ner, nec)
    end,
    on_reload = function()
      if active == sess then
        M.stop()
      end
    end,
  })

  map_key(sess, "<Home>", function()
    move_each(sess, home)
  end, "Move every cursor to its line start")
  map_key(sess, "<End>", function()
    move_each(sess, line_end)
  end, "Move every cursor to its line end")
  if sess.pending then
    map_key(sess, "<Left>", function()
      collapse(sess, true)
    end, "Collapse every selection to its start")
    map_key(sess, "<Right>", function()
      collapse(sess, false)
    end, "Collapse every selection to its end")
  end

  -- `startinsert` from a mapping only takes effect once the mapping returns.
  local row, col = sess.primary.pos[1], sess.primary.pos[2]
  api.nvim_win_set_cursor(win, { row + 1, col })
  vim.cmd(col >= #get_line(buf, row) and "startinsert!" or "startinsert")

  api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "CursorMovedI" }, {
    group = augroup,
    callback = function()
      update(sess)
    end,
  })
  api.nvim_create_autocmd("InsertEnter", {
    group = augroup,
    once = true,
    callback = function()
      if active == sess then
        render(sess)
      end
    end,
  })
  api.nvim_create_autocmd("InsertLeave", {
    group = augroup,
    callback = function()
      if active == sess and not sess.diverged and api.nvim_get_current_buf() == buf then
        replay(sess)
      end
      M.stop()
    end,
  })
  api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = augroup,
    callback = M.stop,
  })
end

return M
