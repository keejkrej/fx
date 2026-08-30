-- Screenshot clipboard-buffer paste plugin. Second Lua plugin-system demo:
-- it registers an `fx.paste.hook` interceptor. Screenshot copy on Omarchy,
-- Hyprland, Windows, or Linux puts image bytes on the clipboard, not a file
-- path. The hook asks the host to snapshot those bytes to tmp, then feeds
-- that path into the existing image-attach pipeline so the agent sees a
-- normal file. Text pastes pass through. A pasted image file path is
-- attached the same way.

local M = {}

local IMAGE_EXT = {
  png = true,
  jpg = true,
  jpeg = true,
  gif = true,
  webp = true,
}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_quotes(s)
  if #s >= 2 then
    local first, last = s:sub(1, 1), s:sub(-1)
    if (first == "'" or first == '"') and first == last then
      return s:sub(2, -2)
    end
  end
  return s
end

local function decode_file_url(s)
  local path = s:match("^file://(.*)$")
  if not path then
    return s
  end
  path = path:gsub("^localhost", "")
  path = path:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  return path
end

local function image_path_from_text(text)
  if type(text) ~= "string" or text:find("[\r\n]") then
    return nil
  end
  local path = decode_file_url(strip_quotes(trim(text)))
  if path == "" then
    return nil
  end
  local ext = path:match("%.([%w]+)$")
  if ext and IMAGE_EXT[ext:lower()] then
    return path
  end
  return nil
end

function M.on_paste(event)
  if event.source == "clipboard" then
    local path = fx.clipboard.image_path()
    if path then
      fx.image.attach(path)
      return true
    end
    return false
  end
  local path = image_path_from_text(event.text)
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
