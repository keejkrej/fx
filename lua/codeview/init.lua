-- In-TUI code viewer plugin. Registers a named full-screen view: the host
-- cycles agent / registered views with Ctrl-T. This opener takes over the
-- entire TUI through fx's existing file viewer (syntax highlighting when
-- fx already knows the language). It does not split the terminal.
--
-- `/codeview [path]` opens a workspace file. With no path it reopens the
-- last file, or `lua/codeview/demo.lua`. `/view [path]` is the same viewer
-- and joins the cycle when this plugin is loaded.
--
-- Comments stay on the diff view. This plugin is browse/open only.

local M = {}

local DEFAULT = "lua/codeview/demo.lua"
M.path = DEFAULT

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.open(payload)
  local path = trim(payload or "")
  if path == "" then
    path = M.path
  else
    M.path = path
  end
  fx.view.open(path)
end

function M.setup()
  fx.view.register("code", function()
    M.open("")
  end)
  fx.command("codeview", M.open, {
    desc = "Open a file in the full-screen code viewer; Ctrl-T cycles views",
  })
end

M.setup()
return M
