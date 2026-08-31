-- Workspace Lua plugins. `lua/views` is the full-screen view pack:
-- `lua/diffview` and `lua/codeview` each register with `fx.view.register`.
-- Ctrl-T cycles agent / diff / code. `lua/clipboard_paste` fills Linux/Windows
-- screenshot buffer paste; macOS clipboard images stay first-class in core.
require("views")
require("clipboard_paste")
