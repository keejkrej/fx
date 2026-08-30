-- Diff-view plugin demo for fx's Lua plugin system.
-- Registers `/diffview`, then opens the built-in code viewer on a canned
-- old/new pair. That is the whole point: a real plugin that registers,
-- renders, and lets you move around a diff (j/k, [/] hunks, t layout, q).

local M = {}

local DEMO_PATH = "lua/diffview/demo.lua"

local DEMO_OLD = [[local function greet(name)
  return "hello, " .. name
end

print(greet("world"))
print("DIFFVIEW_DEMO_KEEP")
print("DIFFVIEW_DEMO_OLD")
]]

local DEMO_NEW = [[local function greet(name)
  return "hello, " .. name .. "!"
end

print(greet("fx"))
print("DIFFVIEW_DEMO_KEEP")
print("DIFFVIEW_DEMO_NEW")
print("lua plugin demo")
]]

local function trim(text)
  return (text:match("^%s*(.-)%s*$")) or ""
end

function M.open(payload)
  local path = DEMO_PATH
  if type(payload) == "string" then
    local labeled = trim(payload)
    if labeled ~= "" then
      path = labeled
    end
  end
  fx.view.diff(path, DEMO_OLD, DEMO_NEW, { line = 2 })
end

function M.setup()
  fx.command("diffview", M.open, {
    desc = "Open the Lua plugin diff-view demo",
  })
end

M.setup()
return M
