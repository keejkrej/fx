-- Screenshot clipboard-buffer paste plugin. Second Lua plugin-system demo:
-- it registers an `fx.paste.hook` interceptor for the Linux/Windows gap.
-- macOS already pastes clipboard images in first-class core (osascript PNGf
-- → tmp snapshot → [Image N]). This plugin must not consume that path.
-- On Omarchy/Hyprland/Windows, screenshot copy puts image bytes on the
-- clipboard. The hook asks the host to snapshot those bytes to tmp, then
-- feeds that path into the existing image-attach pipeline. Text passes through.

local M = {}

function M.on_paste(event)
  if event.os == "macos" then
    return false
  end
  if event.source ~= "clipboard" then
    return false
  end
  local path = fx.clipboard.image_path()
  if path then
    fx.image.attach(path)
    return true
  end
  return false
end

function M.setup()
  fx.paste.hook(M.on_paste)
end

M.setup()
return M
