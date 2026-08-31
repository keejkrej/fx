-- CODEVIEW_DEMO: in-TUI file viewer plugin.
-- Ctrl-T cycles agent / diff / code. Each mode owns the whole terminal.

local function greet(name)
  return "hello, " .. name
end

print(greet("fx"))
print("CODEVIEW_DEMO_LINE")
