-- End-to-end tests: every case drives a fresh child Neovim with real key
-- presses (nvim_input), the same path a user's keyboard goes through.
--
-- Run with: nvim --headless --clean -l tests/run.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function spawn()
  local chan = vim.fn.jobstart({ "nvim", "--embed", "--headless", "--clean", "-n" }, { rpc = true })
  local function req(method, ...)
    return vim.rpcrequest(chan, method, ...)
  end
  req("nvim_exec_lua", "vim.opt.rtp:prepend(...)", { root })
  req("nvim_command", "runtime plugin/multi_cursors_vsc.lua")
  req("nvim_exec_lua", "require('multi_cursors_vsc').setup()", {})
  req("nvim_command", "inoremap jj <Esc>")
  return chan, req
end

local function settle(req)
  -- nvim_input is asynchronous: wait until the child drained its typeahead.
  vim.wait(1000, function()
    return req("nvim_exec_lua", "return vim.fn.getchar(1) == 0", {}) and not req("nvim_get_mode").blocking
  end, 10)
  vim.wait(30)
end

local function type_keys(req, keys)
  req("nvim_input", keys)
  settle(req)
end

local failures, passed = 0, 0

local function case(name, opts)
  local chan, req = spawn()
  req("nvim_buf_set_lines", 0, 0, -1, true, opts.lines)
  if opts.setup then
    opts.setup(req)
  end
  req("nvim_win_set_cursor", 0, opts.cursor or { 1, 0 })
  for _, keys in ipairs(opts.keys) do
    type_keys(req, keys)
  end
  local got = req("nvim_buf_get_lines", 0, 0, -1, true)
  local ok, err = true, nil
  if not vim.deep_equal(got, opts.expect) then
    ok, err = false, ("lines\n  expected: %s\n  got:      %s"):format(vim.inspect(opts.expect), vim.inspect(got))
  elseif opts.check then
    ok, err = pcall(opts.check, req)
  end
  if ok then
    passed = passed + 1
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. "\n  " .. tostring(err))
  end
  vim.fn.jobstop(chan)
end

local function eq(expected, got, what)
  if not vim.deep_equal(expected, got) then
    error(("%s: expected %s, got %s"):format(what, vim.inspect(expected), vim.inspect(got)), 2)
  end
end

local function mode_is(req, mode)
  eq(mode, req("nvim_get_mode").mode, "mode")
end

local function fake_cursors(req)
  return req(
    "nvim_exec_lua",
    [[
      local ns = vim.api.nvim_get_namespaces().multi_cursors_vsc_cursors
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})) do
        table.insert(out, { m[2], m[3] })
      end
      return out
    ]],
    {}
  )
end

case("V + Alt+Shift+i types at every line end", {
  lines = { "one", "two", "three" },
  keys = { "Vjj", "<M-I>", "foo", "<Esc>" },
  expect = { "onefoo", "twofoo", "threefoo" },
  check = function(req)
    mode_is(req, "n")
    eq({}, fake_cursors(req), "fake cursors after exit")
  end,
})

case("jj mapping applies and exits", {
  lines = { "a", "b" },
  keys = { "Vj", "<M-I>", ";", "jj" },
  expect = { "a;", "b;" },
  check = function(req)
    mode_is(req, "n")
  end,
})

case("charwise visual also targets line ends", {
  lines = { "alpha beta", "gamma", "delta" },
  cursor = { 1, 3 },
  keys = { "vj", "<M-I>", "!", "<Esc>" },
  expect = { "alpha beta!", "gamma!", "delta" },
})

case("selection made upwards", {
  lines = { "x", "y", "z" },
  cursor = { 3, 0 },
  keys = { "Vkk", "<M-I>", "1", "<Esc>" },
  expect = { "x1", "y1", "z1" },
  check = function(req)
    eq({ 1, 1 }, req("nvim_win_get_cursor", 0), "primary cursor stays on cursor line")
  end,
})

case("fake cursors shown while typing", {
  lines = { "aa", "bb", "cc" },
  keys = { "Vjj", "<M-I>", "x" },
  expect = { "aax", "bbx", "ccx" },
  check = function(req)
    mode_is(req, "i")
    eq({ { 0, 3 }, { 1, 3 } }, fake_cursors(req), "fake cursors at line ends")
  end,
})

case("backspace inside typed text", {
  lines = { "a", "b" },
  keys = { "Vj", "<M-I>", "xyz<BS><BS>q", "<Esc>" },
  expect = { "axq", "bxq" },
})

case("backspace past the start deletes at every cursor", {
  lines = { "abc", "def", "ghi" },
  keys = { "Vjj", "<M-I>", "<BS><BS>Z", "<Esc>" },
  expect = { "aZ", "dZ", "gZ" },
})

case("<C-w> deletes a word at every cursor", {
  lines = { "foo bar", "baz qux" },
  keys = { "Vj", "<M-I>", "<C-w>X", "<Esc>" },
  expect = { "foo X", "baz X" },
})

case("<C-u> deletes typed text at every cursor", {
  lines = { "ab", "cd" },
  keys = { "Vj", "<M-I>", "xyz<C-u>Q", "<Esc>" },
  expect = { "abQ", "cdQ" },
})

case("<CR> splits every line", {
  lines = { "a", "b" },
  keys = { "Vj", "<M-I>", "1<CR>2", "<Esc>" },
  expect = { "a1", "2", "b1", "2" },
})

case("multibyte text", {
  lines = { "สวัสดี", "héllo", "日本" },
  keys = { "Vjj", "<M-I>", "→ü", "<BS><BS><BS>", "語", "<Esc>" },
  expect = { "สวัสด語", "héll語", "日語" },
})

case("arrow keys move every cursor", {
  lines = { "abc", "def" },
  keys = { "Vj", "<M-I>", "<Left><Left>-", "<End>!", "<Esc>" },
  expect = { "a-bc!", "d-ef!" },
})

case("arrow keys typed one by one", {
  lines = { "abc", "def" },
  keys = { "Vj", "<M-I>", "<Left>", "<Left>", "-", "<End>", "!", "<Esc>" },
  expect = { "a-bc!", "d-ef!" },
})

case("<Left> stops at column 0 and cursors keep their distance", {
  lines = { "abcdef", "g" },
  keys = { "Vj", "<M-I>", "<Left><Left><Left>|", "<Esc>" },
  expect = { "abcde|f", "|g" },
})

case("<Del> at line end joins at every cursor", {
  lines = { "a", "b", "c", "d" },
  setup = function(req)
    req("nvim_command", "set backspace=indent,eol,start")
  end,
  keys = { "Vj", "<M-I>", "<Left><Del>", "<Esc>" },
  expect = { "", "", "c", "d" },
})

case("vertical move ends the session", {
  lines = { "a", "b", "c" },
  keys = { "Vj", "<M-I>", "1", "<Down>", "2", "<Esc>" },
  expect = { "a1", "b1", "c2" },
  check = function(req)
    eq({}, fake_cursors(req), "fake cursors")
  end,
})

case("blockwise visual inserts at the block's left column", {
  lines = { "abcd", "ab", "abcd", "abcd" },
  cursor = { 1, 2 },
  keys = { "<C-v>jjjl", "<M-I>", "|", "<Esc>" },
  expect = { "ab|cd", "ab|", "ab|cd", "ab|cd" },
})

case("blockwise visual skips lines too short", {
  lines = { "abcd", "a", "abcd" },
  cursor = { 1, 2 },
  keys = { "<C-v>jj", "<M-I>", "|", "<Esc>" },
  expect = { "ab|cd", "a", "ab|cd" },
})

case("blockwise visual with tabs uses display columns", {
  lines = { "\tx", "12345678y" },
  setup = function(req)
    req("nvim_command", "set tabstop=8 noexpandtab")
  end,
  cursor = { 1, 1 },
  keys = { "<C-v>j", "<M-I>", "|", "<Esc>" },
  expect = { "\t|x", "12345678|y" },
})

case("blockwise visual with $ goes to line ends", {
  lines = { "abcd", "ab" },
  keys = { "<C-v>j$", "<M-I>", ";", "<Esc>" },
  expect = { "abcd;", "ab;" },
})

case("single undo reverts the whole edit", {
  lines = { "a", "b", "c" },
  keys = { "Vjj", "<M-I>", "hello", "<Esc>", "u" },
  expect = { "a", "b", "c" },
})

case(":MultiCursorsLineEnds with a range", {
  lines = { "a", "b", "c" },
  keys = { ":1,2MultiCursorsLineEnds<CR>", "+", "<Esc>" },
  expect = { "a+", "b+", "c" },
})

case("completion popup accept is mirrored", {
  lines = { "foobar", "x", "y" },
  cursor = { 2, 0 },
  keys = { "Vj", "<M-I>", " foo<C-n>", "<C-y>", "<Esc>" },
  expect = { "foobar", "x foobar", "y foobar" },
})

case("custom keymap via setup", {
  lines = { "a", "b" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ keymaps = { line_ends = '<leader>m' } })", {})
  end,
  keys = { "Vj", "\\m", "z", "<Esc>" },
  expect = { "az", "bz" },
  check = function(req)
    eq(vim.empty_dict(), req("nvim_exec_lua", "return vim.fn.maparg('<M-I>', 'x', false, true)", {}), "old map removed")
  end,
})

case("autopairs-style mapping that moves the cursor", {
  lines = { "a", "b" },
  setup = function(req)
    req("nvim_command", "inoremap ( ()<Left>")
  end,
  keys = { "Vj", "<M-I>", "(", "x", "<Esc>" },
  expect = { "a(x)", "b(x)" },
})

case("<BS> at column 0 joins lines at every cursor", {
  lines = { "a", "b", "c", "d" },
  cursor = { 2, 0 },
  keys = { "<C-v>jj", "<M-I>", "<BS>", "<Esc>" },
  expect = { "abcd" },
})

case("V j 0 then Alt+Shift+i: cursors at column 0", {
  lines = { "  indented", "flush", "end" },
  cursor = { 1, 4 },
  keys = { "Vj", "0", "<M-I>", "# ", "<Esc>" },
  expect = { "#   indented", "# flush", "end" },
  check = function(req)
    eq({}, fake_cursors(req), "fake cursors after exit")
  end,
})

case("vip 0 then Alt+Shift+i", {
  lines = { "a", "b", "", "c" },
  keys = { "vip", "0", "<M-I>", "- ", "<Esc>" },
  expect = { "- a", "- b", "", "c" },
})

case("V j ^ then Alt+Shift+i: cursors at the first non-blank", {
  lines = { "  local a", "    local b", "\tlocal c" },
  cursor = { 1, 5 },
  keys = { "Vjj", "^", "<M-I>", "-- ", "<Esc>" },
  expect = { "  -- local a", "    -- local b", "\t-- local c" },
})

case("cursor already at column 0 without pressing 0 still targets line ends", {
  lines = { "ab", "cd" },
  keys = { "Vj", "<M-I>", "!", "<Esc>" },
  expect = { "ab!", "cd!" },
})

case("0 typed earlier, not right before, does not count", {
  lines = { "ab", "cd" },
  keys = { "0", "V", "j", "<M-I>", "!", "<Esc>" },
  expect = { "ab!", "cd!" },
})

case("counts containing 0 are not mistaken for the 0 motion", {
  lines = { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l" },
  keys = { "V10j", "<M-I>", ";", "<Esc>" },
  expect = { "a;", "b;", "c;", "d;", "e;", "f;", "g;", "h;", "i;", "j;", "k;", "l" },
})

case("<Home> moves every cursor to its first non-blank", {
  lines = { "  indented", "flush", "\tTab" },
  keys = { "Vjj", "<M-I>", "<Home>", "- ", "<Esc>" },
  expect = { "  - indented", "- flush", "\t- Tab" },
})

case("<Home> twice goes to column 0", {
  lines = { "  a", "    b" },
  keys = { "Vj", "<M-I>", "<Home>", "<Home>", "#", "<Esc>" },
  expect = { "#  a", "#    b" },
})

case("<End> moves every cursor to its line end", {
  lines = { "ab", "cdef" },
  keys = { "Vj", "<M-I>", "<Home>", "x", "<End>", "y", "<Esc>" },
  expect = { "xaby", "xcdefy" },
})

case("<Home> in a batch with typing", {
  lines = { "one", "two" },
  keys = { "Vj", "<M-I>", "!<Home>-", "<Esc>" },
  expect = { "-one!", "-two!" },
})

case("session <Home> mapping is removed afterwards and buffer maps restored", {
  lines = { "a", "b" },
  setup = function(req)
    req("nvim_command", "inoremap <buffer> <End> END")
  end,
  keys = { "Vj", "<M-I>", "<Esc>" },
  expect = { "a", "b" },
  check = function(req)
    eq(vim.empty_dict(), req("nvim_exec_lua", "return vim.fn.maparg('<Home>', 'i', false, true)", {}), "<Home> map")
    eq("END", req("nvim_exec_lua", "return vim.fn.maparg('<End>', 'i')", {}), "<End> buffer map")
  end,
})

case("Alt+Shift+l: cursors after every match, typing keeps the matches", {
  lines = { "foo = foo + 1", "bar(foo)", "food" },
  setup = function(req)
    req("nvim_command", "set hlsearch")
  end,
  keys = { "/foo\\><CR>", "<M-L>", "_count", "<Esc>" },
  expect = { "foo_count = foo_count + 1", "bar(foo_count)", "food" },
  check = function(req)
    mode_is(req, "n")
    eq({}, fake_cursors(req), "fake cursors after exit")
  end,
})

case("Alt+Shift+l: nothing selected, search highlight stays", {
  lines = { "x foo", "foo y" },
  setup = function(req)
    req("nvim_command", "set hlsearch")
  end,
  keys = { "/foo<CR>", "<M-L>" },
  expect = { "x foo", "foo y" },
  check = function(req)
    mode_is(req, "i")
    eq(1, req("nvim_get_vvar", "hlsearch"), "v:hlsearch")
    eq({ { 1, 3 } }, fake_cursors(req), "only the fake cursor, no selection marks")
    eq({ 1, 5 }, req("nvim_win_get_cursor", 0), "real cursor after the match")
  end,
})

case("Alt+Shift+l: <BS> deletes one character per match", {
  lines = { "foo foo" },
  keys = { "/foo<CR>", "<M-L>", "<BS>", "<Esc>" },
  expect = { "fo fo" },
})

case("Alt+Shift+l: <Left> moves one character", {
  lines = { "foo", "a foo" },
  keys = { "/foo<CR>", "<M-L>", "<Left>", "|", "<Esc>" },
  expect = { "fo|o", "a fo|o" },
})

case("select_matches: typing replaces every search match", {
  lines = { "foo = foo + 1", "bar(foo)", "food" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
  end,
  keys = { "/foo\\><CR>", "<M-L>", "count", "<Esc>" },
  expect = { "count = count + 1", "bar(count)", "food" },
  check = function(req)
    mode_is(req, "n")
    eq({}, fake_cursors(req), "fake cursors after exit")
  end,
})

case("matches are shown selected with fake cursors", {
  lines = { "x foo", "foo y" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
  end,
  keys = { "/foo<CR>", "<M-L>" },
  expect = { "x foo", "foo y" },
  check = function(req)
    mode_is(req, "i")
    local marks = req(
      "nvim_exec_lua",
      [[
        local ns = vim.api.nvim_get_namespaces().multi_cursors_vsc_cursors
        local out = {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
          table.insert(out, { m[2], m[3], m[4].end_col or -1, m[4].hl_group or m[4].virt_text[1][2] })
        end
        return out
      ]],
      {}
    )
    eq({
      { 0, 2, 5, "MultiCursorsVscSelection" },
      { 1, 0, 3, "MultiCursorsVscSelection" },
      { 1, 3, 4, "MultiCursorsVscCursor" },
    }, marks, "selection + cursor marks")
  end,
})

case("search highlighting is hidden so selections are visible", {
  lines = { "foo foo" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
    req("nvim_command", "set hlsearch")
  end,
  keys = { "/foo<CR>", "<M-L>" },
  expect = { "foo foo" },
  check = function(req)
    eq(0, req("nvim_get_vvar", "hlsearch"), "v:hlsearch")
  end,
})

case("<Esc> right away leaves matches unchanged", {
  lines = { "foo foo" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
  end,
  keys = { "/foo<CR>", "<M-L>", "<Esc>" },
  expect = { "foo foo" },
})

case("<Left> collapses to the match start", {
  lines = { "foo bar", "a foo" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
  end,
  keys = { "/foo<CR>", "<M-L>", "<Left>", "my_", "<Esc>" },
  expect = { "my_foo bar", "a my_foo" },
})

case("<Right> collapses to the match end", {
  lines = { "foo bar", "a foo" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
  end,
  keys = { "/foo<CR>", "<M-L>", "<Right>", "()", "<Esc>" },
  expect = { "foo() bar", "a foo()" },
})

case("typing then <Left> in one batch acts as a plain <Left>", {
  lines = { "foo", "x foo" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
  end,
  keys = { "/foo<CR>", "<M-L>", "ab<Left>X", "<Esc>" },
  expect = { "aXb", "x aXb" },
})

case("buffer-local <Left> mapping is restored after the session", {
  lines = { "foo foo" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
    req("nvim_command", "inoremap <buffer> <Left> LEFT")
  end,
  keys = { "/foo<CR>", "<M-L>", "<Left>", "<Esc>" },
  expect = { "foo foo" },
  check = function(req)
    eq("LEFT", req("nvim_exec_lua", "return vim.fn.maparg('<Left>', 'i')", {}), "<Left> buffer map")
  end,
})

case("<BS> deletes every match", {
  lines = { "a foo b", "foo" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
  end,
  keys = { "/foo<CR>", "<M-L>", "<BS>", "<Esc>" },
  expect = { "a  b", "" },
})

case("several matches on one line, multibyte", {
  lines = { "ไก่ ไข่ ไก่", "ไก่" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
  end,
  keys = { "/ไก่<CR>", "<M-L>", "เป็ด", "<Esc>" },
  expect = { "เป็ด ไข่ เป็ด", "เป็ด" },
})

case("smartcase is honoured like n", {
  lines = { "Foo foo FOO" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
    req("nvim_command", "set ignorecase smartcase")
  end,
  keys = { "/Foo<CR>", "<M-L>", "X", "<Esc>" },
  expect = { "X foo FOO" },
})

case("ignorecase is honoured", {
  lines = { "Foo foo FOO" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
    req("nvim_command", "set ignorecase smartcase")
  end,
  keys = { "/foo<CR>", "<M-L>", "X", "<Esc>" },
  expect = { "X X X" },
})

case("/^ then Alt+Shift+l puts a cursor at every line start", {
  lines = { "a", "b", "c" },
  keys = { "/^<CR>", "<M-L>", "> ", "<Esc>" },
  expect = { "> a", "> b", "> c" },
})

case("visual Alt+Shift+l limits matches to the selected lines", {
  lines = { "foo", "foo", "foo" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
  end,
  keys = { "/foo<CR>", "gg", "Vj", "<M-L>", "bar", "<Esc>" },
  expect = { "bar", "bar", "foo" },
})

case(":MultiCursorsMatches defaults to the whole buffer", {
  lines = { "foo", "x", "foo" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
  end,
  keys = { "/foo<CR>", ":MultiCursorsMatches<CR>", "z", "<Esc>" },
  expect = { "z", "x", "z" },
})

case("no search pattern warns and does nothing", {
  lines = { "foo" },
  keys = { "<M-L>" },
  expect = { "foo" },
  check = function(req)
    mode_is(req, "n")
  end,
})

case("single undo reverts a match replacement", {
  lines = { "foo foo", "foo" },
  setup = function(req)
    req("nvim_exec_lua", "require('multi_cursors_vsc').setup({ select_matches = true })", {})
  end,
  keys = { "/foo<CR>", "<M-L>", "bar", "<Esc>", "u" },
  expect = { "foo foo", "foo" },
})

-- Every example from README.md, keys exactly as documented.

case("README: line ends", {
  lines = { "local fruits = {", '  "apple"', '  "banana"', '  "cherry"', "}" },
  cursor = { 2, 0 },
  keys = { "Vjj", "<M-I>", ",", "<Esc>" },
  expect = { "local fruits = {", '  "apple",', '  "banana",', '  "cherry",', "}" },
})

case("README: line starts with 0", {
  lines = { 'print("debug 1")', 'print("debug 2")', 'print("debug 3")' },
  keys = { "Vjj", "0", "<M-I>", "-- ", "<Esc>" },
  expect = { '-- print("debug 1")', '-- print("debug 2")', '-- print("debug 3")' },
})

case("README: line starts with ^ keeps indentation", {
  lines = { "  milk", "  eggs", "  bread" },
  keys = { "vip", "^", "<M-I>", "- [ ] ", "<Esc>" },
  expect = { "  - [ ] milk", "  - [ ] eggs", "  - [ ] bread" },
})

case("README: rename search matches", {
  lines = { "local count = 0", "count = count + 1", "print(count)" },
  keys = { "/count<CR>", "<M-L>", "er", "<Esc>" },
  expect = { "local counter = 0", "counter = counter + 1", "print(counter)" },
})

case("README: * then Ctrl-w replaces the matches", {
  lines = { "local count = 0", "count = count + 1", "print(count)" },
  cursor = { 1, 7 },
  keys = { "*", "<M-L>", "<C-w>total", "<Esc>" },
  expect = { "local total = 0", "total = total + 1", "print(total)" },
})

case("README: /$ puts a cursor at the end of every line", {
  lines = { "a", "bb", "ccc" },
  keys = { "/$<CR>", "<M-L>", ";", "<Esc>" },
  expect = { "a;", "bb;", "ccc;" },
})

case("README: visual block column", {
  lines = { "const A = 1", "const B = 2", "const C = 3" },
  cursor = { 1, 6 },
  keys = { "<C-v>jj", "<M-I>", "MY_", "<Esc>" },
  expect = { "const MY_A = 1", "const MY_B = 2", "const MY_C = 3" },
})

case("README: Home to wrap in parentheses", {
  lines = { "a + b", "x * y" },
  keys = { "Vj", "<M-I>", ")", "<Home>", "(", "<Esc>" },
  expect = { "(a + b)", "(x * y)" },
})

print(("\n%d passed, %d failed"):format(passed, failures))
if failures > 0 then
  os.exit(1)
end
