-- In-TUI diff review plugin. This is the Lua plugin-system demo: it registers
-- `/diffview`, then opens fx's existing code-viewer owner (not a child
-- terminal) on a multi-file review. Side-by-side, a file list, hunk jumps,
-- and add/remove highlighting are the Lumen-shaped bits. The key interaction
-- is review comments: `c` (or `i`) on a hunk types a note, Enter closes the
-- viewer, and the quoted hunk plus note land in the main agent input box.
-- No separate chat; comments are agent context, ready to send.

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
    layout = "side",
  })
end

function M.setup()
  fx.command("diffview", M.open, {
    desc = "Open the in-TUI Lua diff-view demo; c comments a hunk into the agent input",
  })
end

M.setup()
return M
