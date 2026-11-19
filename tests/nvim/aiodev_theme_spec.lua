-- Specification of nvim/lua/aiodev_theme.lua, run as Neovim's init file by tests/live/nvim_theme.ps1:
--   nvim --headless -u aiodev_theme_spec.lua -i NONE -n
-- with SPEC_DIR naming a scratch folder and SPEC_PLUGIN the plugin folder. Exits with the failure count.
local root = vim.fs.normalize(vim.env.SPEC_DIR)
local plugin = vim.fs.normalize(vim.env.SPEC_PLUGIN)
local record_path = root .. "/current.json"
local failures = 0

local function check(name, ok, detail)
  io.stdout:write(string.format("%s %s%s\n", ok and "PASS" or "FAIL", name, ok and "" or (" (" .. tostring(detail) .. ")")))
  io.stdout:flush()
  if not ok then
    failures = failures + 1
  end
end

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

-- The record AIODev would write for a theme, replaced the way AIODev does it: temp file, then rename.
local function record(id, light, colorscheme, background)
  local palette = {}
  for i = 0, 15 do
    palette[#palette + 1] = string.format("#%02x%02x%02x", 16 * i, 255 - 16 * i, 128)
  end
  local neovim
  if colorscheme then
    neovim = { plugin = "owner/" .. colorscheme, colorscheme = colorscheme, background = background }
  end
  return vim.json.encode({
    version = 1,
    generation = 1,
    theme = id,
    name = id,
    light = light,
    neovim = neovim,
    colors = {
      foreground = light and "#202020" or "#d0d0d0",
      background = light and "#f0f0f0" or "#101010",
      cursor = "#ff8800",
      selection = "#334455",
      search_foreground = "#000000",
      search_background = "#ffee00",
      search_selected_background = "#ff8800",
      surface = light and "#e0e0e0" or "#202020",
      muted = "#808080",
      faint = "#707070",
      accent = "#0088ff",
      success = "#00aa00",
      warning = "#aaaa00",
      danger = "#aa0000",
      info = "#0000aa",
      palette = palette,
    },
  })
end

-- The rename retries while the plugin has the record open for reading, as AIODev's writer does.
local function replace(text)
  write_file(record_path .. ".tmp", text)
  for _ = 1, 20 do
    if vim.uv.fs_rename(record_path .. ".tmp", record_path) then
      return
    end
    vim.wait(10)
  end
  error("could not replace " .. record_path)
end

local function publish(text)
  replace(text)
end

local function wait_for(condition, timeout)
  return vim.wait(timeout or 3000, condition, 20)
end

local function normal_background()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  return normal.bg and string.format("#%06x", normal.bg) or "none"
end

-- Colorschemes that stand in for installed community plugins, as the real ones behave: they clear the
-- highlights and set 'background' and g:colors_name.
for name, background in pairs({ ["tokyonight-day"] = "light", ["tokyonight-storm"] = "dark" }) do
  vim.fn.mkdir(root .. "/community/colors", "p")
  write_file(
    root .. "/community/colors/" .. name .. ".lua",
    string.format('vim.cmd("highlight clear") vim.o.background = "%s" vim.g.colors_name = "%s"', background, name)
  )
end
vim.opt.rtp:prepend(root .. "/community")
vim.opt.rtp:append(plugin)

-- An error ends the run: headless Neovim would otherwise sit waiting for input.
local function guarded(run)
  return function()
    local ok, err = xpcall(run, debug.traceback)
    if not ok then
      io.stdout:write("ERROR " .. tostring(err) .. "\n")
      io.stdout:flush()
      vim.cmd("cquit 2")
    end
  end
end

guarded(function()
  -- Outside AIODev the variable is unset and the plugin does nothing.
  vim.env.AIODEV_THEME_FILE = nil
  publish(record("ignored", false, "tokyonight-storm"))
  require("aiodev_theme").setup()
  check("no variable: nothing applied", vim.g.colors_name == nil)
  check("no variable: nothing watching", not pcall(vim.api.nvim_get_autocmds, { group = "aiodev_theme" }))

  package.loaded.aiodev_theme = nil
  vim.env.AIODEV_THEME_FILE = record_path
  publish(record("storm", false, "tokyonight-storm"))
  require("aiodev_theme").setup()
  check("setup waits for VimEnter", vim.g.colors_name == nil)
  require("aiodev_theme").setup()
end)()

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = vim.schedule_wrap(guarded(function()
    check("installed colorscheme applied at start", vim.g.colors_name == "tokyonight-storm", vim.g.colors_name)
    check("background follows the record at start", vim.o.background == "dark", vim.o.background)

    publish(record("day", true, "tokyonight-day"))
    check("live: installed colorscheme follows a rewrite", wait_for(function()
      return vim.g.colors_name == "tokyonight-day"
    end), vim.g.colors_name)
    check("live: background follows", vim.o.background == "light", vim.o.background)

    publish(record("mocha", false, "catppuccin-mocha"))
    check("missing colorscheme falls back to the generated one", wait_for(function()
      return vim.g.colors_name == "aiodev"
    end), vim.g.colors_name)
    check("generated: dark background", vim.o.background == "dark", vim.o.background)
    check("generated: Normal uses the palette background", normal_background() == "#101010", normal_background())
    check("generated: terminal colors set", vim.g.terminal_color_1 == "#10ef80", vim.g.terminal_color_1)
    check("generated: keyword uses the magenta slot", vim.api.nvim_get_hl(0, { name = "Statement" }).fg == 0x50af80)

    publish(record("paper", true))
    check("a theme without a colorscheme is generated", wait_for(function()
      return vim.o.background == "light" and normal_background() == "#f0f0f0"
    end), normal_background())
    check("generated: still the aiodev scheme", vim.g.colors_name == "aiodev", vim.g.colors_name)

    replace('{"version":1,"colors":')
    vim.wait(400)
    check("a broken record changes nothing", vim.o.background == "light" and normal_background() == "#f0f0f0")

    for _ = 1, 4 do
      publish(record("flicker", true))
    end
    publish(record("storm-again", false, "tokyonight-storm"))
    check("a burst of rewrites ends on the last record", wait_for(function()
      return vim.g.colors_name == "tokyonight-storm" and vim.o.background == "dark"
    end), vim.g.colors_name)

    vim.cmd.colorscheme("tokyonight-day")
    vim.api.nvim_exec_autocmds("FocusGained", {})
    vim.wait(200)
    check("focus without a change keeps the user's colorscheme", vim.g.colors_name == "tokyonight-day", vim.g.colors_name)

    vim.cmd.colorscheme("aiodev")
    check(":colorscheme aiodev regenerates from the last record", normal_background() == "#101010", normal_background())

    io.stdout:write(failures == 0 and "ALL PASS\n" or string.format("%d FAILED\n", failures))
    io.stdout:flush()
    vim.cmd("cquit " .. failures)
  end)),
})
