-- In-TUI diff review plugin. Registers a named full-screen view: the host
-- cycles agent / registered views with Ctrl-T. `/diffview` opens this review
-- directly. The plugin takes over the entire TUI through fx's code-viewer
-- owner; it does not split the terminal into agent and diff panes, and it
-- does not open a side-by-side old|new layout.
--
-- Comments: `c` (or `i`) on a hunk types a note. Enter injects the quoted
-- hunk plus note into the agent input and stays in the diff. `q` returns to
-- the agent with that context already in the composer. Ctrl-T continues the
-- view cycle (diff → code → agent when the views pack is loaded).

local M = {}

local FILES = {
  {
    path = "lua/diffview/demo.lua",
    old = [[local function greet(name)
  return "hello, " .. name
end

print(greet("world"))
print("DIFFVIEW_DEMO_KEEP")
print("DIFFVIEW_DEMO_OLD")
]],
    new = [[local function greet(name)
  return "hello, " .. name .. "!"
end

print(greet("fx"))
print("DIFFVIEW_DEMO_KEEP")
print("DIFFVIEW_DEMO_NEW")
print("lua plugin demo")
]],
  },
  {
    path = "README.md",
    old = [[# fx

A terminal coding agent.
]],
    new = [[# fx

A terminal coding agent with an in-TUI diff review.

See `/diffview` and DIFFVIEW_FILE_README.
]],
  },
  {
    path = "src/greet.zig",
    old = [[pub fn greet() []const u8 {
    return "hi";
}
]],
    new = [[pub fn greet(name: []const u8) []const u8 {
    _ = name;
    return "hello from DIFFVIEW_FILE_ZIG";
}
]],
  },
}

function M.open()
  fx.view.diff({
    files = FILES,
    layout = "unified",
  })
end

function M.setup()
  fx.view.register("diff", M.open)
  fx.command("diffview", M.open, {
    desc = "Open the full-screen Lua diff review; Ctrl-T cycles agent / diff / code",
  })
end

M.setup()
return M
