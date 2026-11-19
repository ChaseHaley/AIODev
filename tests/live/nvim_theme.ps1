[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'nvim-theme'
$data = Join-Path $repo "build/verify/$name"
$settings = Join-Path $data 'settings.ini'
# Outside $data, which launch --fresh deletes.
$scratch = Join-Path $repo "build/nvim-scratch-$name"
$nvim = (Get-Command nvim -CommandType Application -ErrorAction Stop).Source
function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    $result | Write-Output
}

# Neovim never reads the owner's configuration or state here: the plugin spec and every pane's Neovim
# take their files from the scratch folder.
foreach ($variable in 'CONFIG', 'DATA', 'STATE', 'CACHE') {
    Set-Item "env:XDG_${variable}_HOME" (Join-Path $scratch 'xdg')
}

# The plugin on its own: a headless Neovim run through its specification.
if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $scratch 'spec') | Out-Null
$env:SPEC_DIR = Join-Path $scratch 'spec'
$env:SPEC_PLUGIN = Join-Path $repo 'nvim'
# Neovim reads a piped standard input, so a run whose input never closes would wait forever: give it an
# empty file. An error in the specification ends the run.
$empty = Join-Path $scratch 'empty.txt'
New-Item -ItemType File -Force $empty | Out-Null
$specOut = Join-Path $scratch 'spec.out'
$specRun = Start-Process $nvim -NoNewWindow -PassThru -RedirectStandardInput $empty `
    -RedirectStandardOutput $specOut -RedirectStandardError "$specOut.err" -ArgumentList @(
        '--headless', '-u', "`"$(Join-Path $repo 'tests/nvim/aiodev_theme_spec.lua')`"", '-i', 'NONE', '-n')
if (-not $specRun.WaitForExit(60000)) { $specRun.Kill(); Write-Output 'The plugin specification timed out.' }
$specCode = $specRun.ExitCode
Get-Content -LiteralPath $specOut, "$specOut.err" | Write-Output
if ($specCode -ne 0) { throw "The plugin specification failed ($specCode)." }

# The plugin in a pane: a Neovim configured the way the documentation says follows each theme change.
function Set-Theme([string] $id) {
    $text = [IO.File]::ReadAllText($settings)
    if ($text -match '(?m)^theme\.name = .*$') {
        $text = [regex]::Replace($text, '(?m)^theme\.name = .*$', "theme.name = $id")
    } else {
        $text += "`ntheme.name = $id`n"
    }
    [IO.File]::WriteAllText($settings, $text)
    Invoke-Aio command settings.reload | Out-Null
    Invoke-Aio expect state "theme.name=$id" | Out-Null
}
function Wait-Log([string] $log, [string] $expected, [string] $what) {
    $last = ''
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $lines = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
        if ($lines.Count -gt 0) { $last = $lines[-1] }
        if ($last -like $expected) { Write-Output "PASS $what -> $expected"; return }
        Start-Sleep -Milliseconds 100
    }
    throw "${what}: expected '$expected', the last line was '$last'."
}
function Stop-Nvim {
    Invoke-Aio key Esc | Out-Null
    Invoke-Aio type ':qa!' | Out-Null
    Invoke-Aio key Enter | Out-Null
    Invoke-Aio wait idle 600 | Out-Null
}
$probe = @'
local log = assert(io.open([[__LOG__]], "a"))
local function line()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  log:write(string.format("colors=%s background=%s normal=%s\n", vim.g.colors_name or "none", vim.o.background,
    normal.bg and string.format("#%06x", normal.bg) or "none"))
  log:flush()
end
vim.api.nvim_create_autocmd({ "ColorScheme", "OptionSet" }, { pattern = "*", callback = vim.schedule_wrap(line) })
vim.api.nvim_create_autocmd("VimEnter", { callback = vim.schedule_wrap(line) })
'@
$withPlugin = @'
vim.opt.rtp:prepend([[__SCRATCH__]] .. "/community")
if vim.env.AIODEV_CLI then vim.opt.rtp:append(vim.fs.dirname(vim.env.AIODEV_CLI) .. "/nvim") require("aiodev_theme").setup() end
'@
New-Item -ItemType Directory -Force (Join-Path $scratch 'community/colors') | Out-Null
foreach ($pair in @(@('tokyonight-day', 'light'), @('tokyonight-storm', 'dark'))) {
    [IO.File]::WriteAllText((Join-Path $scratch "community/colors/$($pair[0]).lua"),
        "vim.cmd('highlight clear') vim.o.background = '$($pair[1])' vim.g.colors_name = '$($pair[0])'")
}
$followLog = Join-Path $scratch 'follow.log'
$plainLog = Join-Path $scratch 'plain.log'
[IO.File]::WriteAllText((Join-Path $scratch 'follow.lua'),
    $withPlugin.Replace('__SCRATCH__', $scratch) + "`n" + $probe.Replace('__LOG__', $followLog))
[IO.File]::WriteAllText((Join-Path $scratch 'plain.lua'), $probe.Replace('__LOG__', $plainLog))
try {
    Invoke-Aio launch --fresh
    # The pane's shell takes XDG_CONFIG_HOME from the registry, so the owner's configuration would sit on
    # Neovim's runtime path; the pane sets its own folders before any Neovim starts.
    $xdg = Join-Path $scratch 'xdg'
    Invoke-Aio run ("`$env:NVIM_APPNAME = 'aiodev-theme-test'; " +
        (('CONFIG', 'DATA', 'STATE', 'CACHE' | ForEach-Object { "`$env:XDG_${_}_HOME = '$xdg'" }) -join '; ')) | Out-Null
    $record = Join-Path $data 'nvim/current.json'
    if (-not (Test-Path -LiteralPath $record)) { throw 'AIODev wrote no theme record at startup.' }
    $first = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
    if ($first.theme -ne 'studio-dark' -or $first.generation -ne 1 -or $first.light) { throw 'The startup record is wrong.' }
    Invoke-Aio run 'Write-Output "THEME_FILE=$env:AIODEV_THEME_FILE"' | Out-Null
    Invoke-Aio expect text "THEME_FILE=$record" | Out-Null
    Write-Output 'PASS the pane environment names the theme record'

    Add-Content -LiteralPath $settings -Value "`ntheme.custom.mine.base = tide-dark`n"
    Set-Theme 'tokyonight-day'
    $day = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
    if ($day.neovim.colorscheme -ne 'tokyonight-day' -or -not $day.light -or $day.generation -lt 2) {
        throw 'The record did not follow the theme.'
    }
    Invoke-Aio run "nvim -u '$(Join-Path $scratch 'follow.lua')' -i NONE -n" --idle 1500 | Out-Null
    Wait-Log $followLog 'colors=tokyonight-day background=light normal=*' 'plugin: installed community light'
    Set-Theme 'tokyonight-storm'
    Wait-Log $followLog 'colors=tokyonight-storm background=dark normal=*' 'plugin: installed community dark'
    Set-Theme 'catppuccin-latte'
    Wait-Log $followLog 'colors=aiodev background=light normal=#eff1f5' 'plugin: community theme not installed'
    Set-Theme 'mine'
    Wait-Log $followLog 'colors=aiodev background=dark normal=#151e26' 'plugin: custom theme'
    Set-Theme 'tokyonight-day'
    Wait-Log $followLog 'colors=tokyonight-day background=light normal=*' 'plugin: back to the community theme'
    Stop-Nvim

    # Without the plugin, Neovim still hears light or dark: it enables mode 2031 and AIODev reports changes.
    Set-Theme 'tokyonight-day'
    Invoke-Aio run "nvim -u '$(Join-Path $scratch 'plain.lua')' -i NONE -n" --idle 1500 | Out-Null
    Wait-Log $plainLog 'colors=none background=light normal=*' 'native: starts light under a light theme'
    Set-Theme 'tokyonight-storm'
    Wait-Log $plainLog 'colors=none background=dark normal=*' 'native: follows a switch to dark'
    Set-Theme 'catppuccin-latte'
    Wait-Log $plainLog 'colors=none background=light normal=*' 'native: follows a switch to light'
    Stop-Nvim
    Write-Output 'PASS the theme record, the pane variable, the plugin and the color scheme reports'
} finally {
    & $ctl --name $name stop | Write-Output
}
