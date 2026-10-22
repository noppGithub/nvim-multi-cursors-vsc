# Records demo.gif. Run from the repository root: vhs demo/demo.tape
#
# VHS cannot send Alt+Shift+<key>, so "Ctrl+[" (ESC) followed by the
# uppercase key is used: the same bytes a terminal sends for Option+Shift+key.

Output demo/demo.gif

Require nvim

Set Shell "bash"
Set FontSize 20
Set Width 1100
Set Height 660
Set Padding 16
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set BorderRadius 10
Set Framerate 24
Set TypingSpeed 110ms

Hide
Type `R=$PWD; cd "$(mktemp -d)"; cp "$R/demo/example.lua" .; clear; nvim -u "$R/demo/init.lua" --noplugin -i NONE -n example.lua`
Enter
Sleep 1.5s
Show

Sleep 1.5s

# 1. A cursor at the end of every selected line.
Type "3G"
Sleep 600ms
Type "Vjj"
Sleep 700ms
Ctrl+[
Type "I"
Sleep 900ms
Type ","
Sleep 900ms
Escape
Sleep 2s

# 2. Press 0 first: a cursor at the start of every line.
Type "9G"
Sleep 600ms
Type "Vjj"
Sleep 500ms
Type "0"
Sleep 700ms
Ctrl+[
Type "I"
Sleep 900ms
Type "-- "
Sleep 900ms
Escape
Sleep 2s

# 3. A cursor after every match of the last search.
Type "/count"
Sleep 500ms
Enter
Sleep 900ms
Ctrl+[
Type "L"
Sleep 1s
Type "er"
Sleep 900ms
Escape
Sleep 600ms
Sleep 900ms
Hide
Type ":noh | echo"
Enter
Sleep 300ms
Show
Sleep 2.5s
