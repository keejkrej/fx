-- Full-screen view pack. Diff and code plugins each register a named view
-- with `fx.view.register`. Ctrl-T cycles agent → diff → code → agent.
-- `q` always returns to the agent. No pane split.

require("diffview")
require("codeview")
