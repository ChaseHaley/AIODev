-- Makes Neovim follow the active AIODev theme. AIODev writes the theme to the file named by
-- $AIODEV_THEME_FILE and rewrites it on every theme change; outside AIODev the variable is unset and
-- setup() does nothing. Enable it with:
--   if vim.env.AIODEV_CLI then vim.opt.rtp:append(vim.fs.dirname(vim.env.AIODEV_CLI) .. "/nvim") require("aiodev_theme").setup() end
local M = {}

local uv = vim.uv or vim.loop
local DEBOUNCE_MS = 100

local state = { path = nil, text = nil, record = nil, watcher = nil, timer = nil }

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

local function decode(text)
  local ok, record = pcall(vim.json.decode, text)
  if ok and type(record) == "table" and record.version == 1 and type(record.colors) == "table" then
    return record
  end
end

local function rgb(hex)
  return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
end

-- `from` moved `amount` (0 to 1) of the way to `to`, both "#rrggbb".
local function mix(from, to, amount)
  local fr, fg, fb = rgb(from)
  local tr, tg, tb = rgb(to)
  local function channel(a, b)
    return math.floor(a + (b - a) * amount + 0.5)
  end
  return string.format("#%02x%02x%02x", channel(fr, tr), channel(fg, tg), channel(fb, tb))
end

local function highlights(c)
  local p = c.palette
  local fg, bg = c.foreground, c.background
  local red, green, yellow, blue, magenta, cyan = p[2], p[3], p[4], p[5], p[6], p[7]
  local orange = p[12]
  local line = mix(bg, fg, 0.06)
  local border = mix(bg, fg, 0.2)
  local function tint(color, amount)
    return mix(bg, color, amount)
  end
  return {
    Normal = { fg = fg, bg = bg },
    NormalNC = { fg = fg, bg = bg },
    NormalFloat = { fg = fg, bg = c.surface },
    FloatBorder = { fg = c.muted, bg = c.surface },
    FloatTitle = { fg = c.accent, bg = c.surface, bold = true },
    Cursor = { fg = bg, bg = c.cursor },
    CursorLine = { bg = line },
    CursorColumn = { bg = line },
    ColorColumn = { bg = line },
    CursorLineNr = { fg = c.accent, bold = true },
    LineNr = { fg = c.faint },
    SignColumn = { fg = c.faint, bg = bg },
    FoldColumn = { fg = c.faint, bg = bg },
    Folded = { fg = c.muted, bg = line },
    Visual = { bg = c.selection },
    Search = { fg = c.search_foreground, bg = c.search_background },
    CurSearch = { fg = c.search_foreground, bg = c.search_selected_background },
    IncSearch = { fg = c.search_foreground, bg = c.search_selected_background },
    MatchParen = { bg = c.selection, bold = true },
    Pmenu = { fg = fg, bg = c.surface },
    PmenuSel = { bg = c.selection },
    PmenuSbar = { bg = c.surface },
    PmenuThumb = { bg = c.muted },
    StatusLine = { fg = fg, bg = c.surface },
    StatusLineNC = { fg = c.muted, bg = c.surface },
    WinSeparator = { fg = border },
    WinBar = { fg = fg, bg = bg },
    WinBarNC = { fg = c.muted, bg = bg },
    TabLine = { fg = c.muted, bg = c.surface },
    TabLineSel = { fg = fg, bg = bg },
    TabLineFill = { bg = c.surface },
    NonText = { fg = c.faint },
    EndOfBuffer = { fg = c.faint },
    Whitespace = { fg = border },
    SpecialKey = { fg = c.faint },
    Conceal = { fg = c.muted },
    Directory = { fg = blue },
    Title = { fg = blue, bold = true },
    Question = { fg = green },
    MoreMsg = { fg = green },
    ModeMsg = { fg = fg, bold = true },
    ErrorMsg = { fg = red },
    WarningMsg = { fg = yellow },
    Comment = { fg = c.muted, italic = true },
    Constant = { fg = orange },
    String = { fg = green },
    Character = { fg = red },
    Number = { fg = orange },
    Boolean = { fg = orange },
    Float = { fg = orange },
    Identifier = { fg = red },
    Function = { fg = blue },
    Statement = { fg = magenta },
    Operator = { fg = cyan },
    PreProc = { fg = yellow },
    Include = { fg = blue },
    Define = { fg = magenta },
    Macro = { fg = red },
    Type = { fg = yellow },
    Special = { fg = cyan },
    Delimiter = { fg = fg },
    Debug = { fg = red },
    Underlined = { fg = blue, underline = true },
    Ignore = { fg = c.faint },
    Error = { fg = red },
    Todo = { fg = bg, bg = yellow, bold = true },
    DiffAdd = { bg = tint(green, 0.2) },
    DiffChange = { bg = tint(blue, 0.2) },
    DiffDelete = { bg = tint(red, 0.2) },
    DiffText = { bg = tint(blue, 0.35) },
    Added = { fg = green },
    Changed = { fg = blue },
    Removed = { fg = red },
    DiagnosticError = { fg = c.danger },
    DiagnosticWarn = { fg = c.warning },
    DiagnosticInfo = { fg = c.info },
    DiagnosticHint = { fg = cyan },
    DiagnosticOk = { fg = c.success },
    DiagnosticUnderlineError = { undercurl = true, sp = c.danger },
    DiagnosticUnderlineWarn = { undercurl = true, sp = c.warning },
    DiagnosticUnderlineInfo = { undercurl = true, sp = c.info },
    DiagnosticUnderlineHint = { undercurl = true, sp = cyan },
    SpellBad = { undercurl = true, sp = red },
    SpellCap = { undercurl = true, sp = yellow },
    SpellLocal = { undercurl = true, sp = cyan },
    SpellRare = { undercurl = true, sp = magenta },
    LspReferenceText = { bg = c.selection },
    LspReferenceRead = { bg = c.selection },
    LspReferenceWrite = { bg = c.selection },
  }
end

-- The colorscheme generated from the theme's palette, applied by `:colorscheme aiodev`.
function M.generate()
  local record = state.record
  if not record then
    return
  end
  vim.cmd("highlight clear")
  if vim.fn.exists("syntax_on") == 1 then
    vim.cmd("syntax reset")
  end
  vim.g.colors_name = "aiodev"
  for group, spec in pairs(highlights(record.colors)) do
    vim.api.nvim_set_hl(0, group, spec)
  end
  for i, color in ipairs(record.colors.palette) do
    vim.g["terminal_color_" .. (i - 1)] = color
  end
end

local function apply(record)
  local neovim = type(record.neovim) == "table" and record.neovim or nil
  vim.o.termguicolors = true
  vim.o.background = neovim and neovim.background or (record.light and "light" or "dark")
  if neovim and neovim.colorscheme and pcall(vim.cmd.colorscheme, neovim.colorscheme) then
    return
  end
  vim.cmd.colorscheme("aiodev")
end

local function reload()
  local text = read_file(state.path)
  if not text or text == state.text then
    return
  end
  local record = decode(text)
  if not record then
    return
  end
  state.text, state.record = text, record
  apply(record)
end

local function watch(path)
  local directory, file = vim.fs.dirname(path), vim.fs.basename(path)
  state.timer = uv.new_timer()
  state.watcher = uv.new_fs_event()
  local started = state.watcher:start(directory, {}, function(err, name)
    if err or name ~= file then
      return
    end
    state.timer:stop()
    state.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(reload))
  end)
  if not started then
    state.watcher = nil
  end
end

-- Applies the theme AIODev wrote and follows it. The theme's Neovim colorscheme is used when it is
-- installed, and otherwise one generated from its palette. Does nothing outside AIODev.
function M.setup()
  local path = vim.env.AIODEV_THEME_FILE
  if not path or path == "" or state.path then
    return
  end
  state.path = path
  local group = vim.api.nvim_create_augroup("aiodev_theme", { clear = true })
  vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = reload })
  if vim.v.vim_did_enter == 1 then
    reload()
  else
    vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = reload })
  end
  watch(path)
end

return M
