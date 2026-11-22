-- Reports Neovim's progress messages (Neovim 0.12's nvim_echo with kind 'progress': vim.pack,
-- :checkhealth, plugins) to AIODev as OSC 7501 program status, so they show in its tabs, pane headers,
-- Activity and taskbar (WORK-548). A Neovim pane's client sends each report over its RPC channel; in a
-- terminal pane, setup() writes them to the terminal, which aiodev_theme.setup() turns on. Outside
-- AIODev ($AIODEV_CLI unset) setup() does nothing.
local M = {}

local STATES = { running = "working", success = "done", failed = "error", cancel = "clear" }

-- A field of base64 text, or nil for none; a message's text comes as its chunks' strings.
local function text(field, value, limit)
  if type(value) == "table" then
    local parts = {}
    for _, part in ipairs(value) do
      if type(part) == "string" then
        parts[#parts + 1] = part
      end
    end
    value = table.concat(parts)
  end
  if type(value) ~= "string" then
    return nil
  end
  value = value:gsub("%c", " ")
  if #value > limit then
    -- Cut at the limit, then drop a character the cut split.
    value = value:sub(1, limit):gsub("[\192-\255][\128-\191]*$", "")
  end
  if value ~= "" then
    return field .. "=" .. vim.base64.encode(value)
  end
end

-- The OSC 7501 report for a Progress event's data, or nil for none: running is working with its
-- percent, success done, failed error, and cancel clears it. Neovim's own messages (source 'nvim': each
-- file read and write) are left out, or every :w would leave a finished report.
function M.report(data)
  if type(data) ~= "table" or data.id == nil or not STATES[data.status] or data.source == "nvim" then
    return nil
  end
  local id = tostring(data.id):gsub("[^%w_%.%+%-]", ""):sub(1, 27)
  local fields = { "state=" .. STATES[data.status], "id=nvim-" .. id }
  if data.status ~= "cancel" then
    fields[#fields + 1] = "app=nvim"
    if data.status == "running" and type(data.percent) == "number" then
      fields[#fields + 1] = "progress=" .. math.max(0, math.min(100, math.floor(data.percent)))
    end
    fields[#fields + 1] = text("title", data.title, 192)
    fields[#fields + 1] = text("msg", data.text, 2048)
  end
  return "\27]7501;" .. table.concat(fields, ":") .. "\27\\"
end

-- Writes each progress message's report to the terminal Neovim runs in. Calling it again replaces the
-- autocmd rather than adding another.
function M.setup()
  if not vim.env.AIODEV_CLI or not vim.api.nvim_ui_send then
    return
  end
  local group = vim.api.nvim_create_augroup("aiodev_progress", { clear = true })
  vim.api.nvim_create_autocmd("Progress", {
    group = group,
    callback = function(event)
      local report = M.report(event.data)
      if report then
        vim.api.nvim_ui_send(report)
      end
    end,
  })
end

return M
