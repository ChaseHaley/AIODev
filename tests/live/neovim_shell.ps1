[CmdletBinding()]
param([string] $Name = 'neovim-shell')
# Neovim panes behave as Neovim run from a shell (WORK-545). `aio pane.open_neovim` typed in a shell pane
# opens Neovim in that pane over the shell, taking the pane only once Neovim has drawn, and quitting Neovim
# or choosing the shell's profile in the pane switcher shows the same shell again. Typing hides the pointer
# until the mouse moves. Closing the pane, its tab or AIODev with an unsaved buffer asks first. Neovim
# opened beside a pane leaves a shell in its folder when it quits. Needs nvim on PATH. Neovim runs with XDG
# folders inside this journey's work folder, so the owner's Neovim config is neither read nor written.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$aio = Join-Path $repo 'build/aio.exe'
$work = Join-Path $repo "build/verify/$Name-files"
$settings = Join-Path $work 'settings.ini'
$env:AIODEV_PANE = $null
$env:AIODEV_CLI = $null
$env:NVIM_APPNAME = $null
foreach ($folder in 'CONFIG', 'DATA', 'STATE', 'CACHE') {
    Set-Item "env:XDG_$($folder)_HOME" (Join-Path $work "xdg/$($folder.ToLower())")
}

function Invoke-Ctl {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    return $out
}
function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Ctl state)) {
        $at = $line.IndexOf('=')
        if ($at -gt 0) { $state[$line.Substring(0, $at)] = $line.Substring($at + 1).Trim('"') }
    }
    return $state
}
function Wait-For([string] $Key, [string] $Value) {
    for ($i = 0; $i -lt 80; $i++) {
        if ((Read-State)[$Key] -eq $Value) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for $Key=$Value; saw $((Read-State)[$Key])."
}
function Check([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Wait-Until([scriptblock] $Condition, [string] $Message) {
    for ($i = 0; $i -lt 80; $i++) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    }
    throw $Message
}
function Send-Command([string] $Command) {
    Invoke-Ctl type ":$Command" | Out-Null
    Invoke-Ctl key Enter | Out-Null
}
# The text of the focused Neovim's screen, every row.
function Screen-Text {
    $state = Read-State
    return ($state.Keys | Where-Object { $_ -match '^neovim\.row\.\d+$' } | ForEach-Object { $state[$_] }) -join "`n"
}
# Waits for Neovim to take the focused pane, which must already show a window Neovim drew: its first
# flush, before its config has run, holds only an empty base grid.
function Wait-Drawn {
    for ($i = 0; $i -lt 200; $i++) {
        $state = Read-State
        if ($state['neovim.active'] -eq 'true') {
            Check ([int] $state['neovim.grids'] -gt 1) 'the pane showed Neovim before Neovim drew a window'
            Check ($state['neovim.started'] -eq 'true') 'the pane showed a Neovim that has not started'
            return
        }
    }
    throw 'Neovim did not take the pane.'
}

if (-not (Get-Command nvim -ErrorAction SilentlyContinue)) { throw 'This journey needs nvim on PATH.' }
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
Set-Content -LiteralPath (Join-Path $work 'notes.txt') -Encoding utf8 -NoNewline "first line`nsecond line`n"
# A config that waits on the event loop while it loads, as plugin managers do, so Neovim's first flush,
# an empty base grid, arrives well before its first window: the owner's flicker.
New-Item -ItemType Directory -Force (Join-Path $work 'xdg/config/nvim') | Out-Null
Set-Content -LiteralPath (Join-Path $work 'xdg/config/nvim/init.lua') -Encoding utf8 'vim.wait(150)'
@"
control.enabled = true
profile.default.command = pwsh.exe -NoLogo -NoProfile -NoExit
profile.default.directory = $work
shell.default_profile = default
profile.order = default
cursor.blink = false
window.columns = 150
window.rows = 40
"@ | Set-Content -LiteralPath $settings -Encoding utf8

Invoke-Ctl launch --fresh --settings $settings | Out-Null
try {
    Invoke-Ctl wait text 'PS ' | Out-Null

    # Typed in the shell as the user would: Neovim takes this pane, over the shell, and does not split. It
    # takes the pane only once it has drawn, so the pane never shows an empty Neovim.
    Invoke-Ctl type "& '$aio' pane.open_neovim notes.txt" | Out-Null
    Invoke-Ctl key Enter | Out-Null
    Wait-Drawn
    Wait-For 'neovim.row.0' 'first line'
    $state = Read-State
    Check ($state['tab.1.panes'] -eq '1') "Neovim split the tab into $($state['tab.1.panes']) panes"
    Check ($state['neovim.shell'] -ne '0') 'Neovim has no shell behind it'

    # Typing into Neovim hides the pointer until the mouse moves again.
    Invoke-Ctl focus in | Out-Null
    $caret = (Read-State)['caret.rect'] -split ','
    $x, $y = ([int] $caret[0] + 60), ([int] $caret[1] + 60)
    Invoke-Ctl mouse move "$x,$y" --px | Out-Null
    Check ((Read-State)['pointer.shape'] -ne 'hidden') 'the pointer was hidden before any typing'
    Invoke-Ctl key i | Out-Null
    Invoke-Ctl type 'changed ' | Out-Null
    Invoke-Ctl key Esc | Out-Null
    Wait-For 'neovim.row.0' 'changed first line'
    Wait-For 'pointer.shape' 'hidden'
    Invoke-Ctl mouse move "$($x + 8),$y" --px | Out-Null
    Check ((Read-State)['pointer.shape'] -ne 'hidden') 'the pointer stayed hidden after the mouse moved'

    # With the buffer unsaved, closing the pane lets Neovim ask; Cancel keeps both.
    Wait-For 'neovim.unsaved' '1'
    Invoke-Ctl command pane.close | Out-Null
    Wait-For 'neovim.closing' 'true'
    Wait-Until { (Screen-Text) -like '*Save changes*' } "Neovim did not ask about the unsaved buffer"
    Invoke-Ctl type 'c' | Out-Null
    Wait-For 'neovim.closing' 'false'
    Check ((Read-State)['neovim.count'] -eq '1') 'the pane closed although the question was cancelled'

    # Closing the tab or AIODev asks in AIODev's own question; Esc cancels each.
    Invoke-Ctl command tab.close | Out-Null
    Wait-For 'confirm.open' 'true'
    Check ((Read-State)['confirm.title'] -eq 'Close tab with unsaved changes?') "tab question: $((Read-State)['confirm.title'])"
    Invoke-Ctl key Esc | Out-Null
    Wait-For 'confirm.open' 'false'
    Invoke-Ctl command app.quit | Out-Null
    Wait-For 'quit.open' 'true'
    Invoke-Ctl key Esc | Out-Null
    Wait-For 'quit.open' 'false'
    Check ((Read-State)['neovim.count'] -eq '1') 'a cancelled question closed Neovim'

    # Quitting Neovim shows the same shell again, with the command that opened Neovim still on screen.
    Send-Command 'q!'
    Wait-For 'neovim.active' 'false'
    Wait-For 'neovim.count' '0'
    Check ((Read-State)['tab.1.panes'] -eq '1') 'the pane closed instead of showing its shell'
    Invoke-Ctl wait text 'notes.txt' | Out-Null

    # The pane switcher's shell profile shows the shell behind Neovim again rather than starting another:
    # Neovim quits, and its first command is still on the shell's screen.
    Invoke-Ctl type "& '$aio' pane.open_neovim notes.txt" | Out-Null
    Invoke-Ctl key Enter | Out-Null
    Wait-Drawn
    Invoke-Ctl command pane.change_shell | Out-Null
    Wait-For 'profile_menu.open' 'true'
    Invoke-Ctl key Enter | Out-Null
    Wait-For 'neovim.active' 'false'
    Wait-For 'neovim.count' '0'
    Check ((Read-State)['tab.1.panes'] -eq '1') 'the switcher closed the pane'
    Invoke-Ctl wait text 'notes.txt' | Out-Null

    # Swap pane to Neovim's default shortcut does what the pane switcher's Neovim does: Neovim takes the
    # focused shell pane, over the shell, which shows again when Neovim quits.
    Invoke-Ctl key Ctrl+Shift+G | Out-Null
    Wait-Drawn
    $state = Read-State
    Check ($state['tab.1.panes'] -eq '1') "the shortcut split the tab into $($state['tab.1.panes']) panes"
    Check ($state['neovim.shell'] -ne '0') 'Neovim opened by the shortcut has no shell behind it'
    Send-Command 'q'
    Wait-For 'neovim.active' 'false'
    Wait-For 'neovim.count' '0'
    Invoke-Ctl wait text 'notes.txt' | Out-Null

    # Neovim opened beside the shell, not from it, leaves a shell in its folder when it quits.
    Invoke-Ctl command pane.open_neovim | Out-Null
    Wait-For 'neovim.started' 'true'
    Check ((Read-State)['tab.1.panes'] -eq '2') 'Open Neovim did not split beside the shell'
    Check ((Read-State)['neovim.shell'] -eq '0') 'Neovim opened beside the shell has a shell behind it'
    Send-Command 'q'
    Wait-For 'neovim.active' 'false'
    Wait-For 'neovim.count' '0'
    Check ((Read-State)['tab.1.panes'] -eq '2') 'the pane closed instead of becoming a shell'
    Invoke-Ctl wait text 'PS ' | Out-Null
    Write-Output 'PASS neovim_shell'
} finally {
    & $ctl --name $Name stop | Out-Null
}
