[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'palette-keybindings'
$path = Join-Path $repo "build/verify/$name/settings.ini"

function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}

function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Aio state)) {
        $pair = $line -split '=', 2
        if ($pair.Count -eq 2) { $state[$pair[0]] = $pair[1].Trim('"') }
    }
    return $state
}

function Assert-Value($Actual, $Expected, [string] $Label) {
    if ($Actual -ne $Expected) { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}

Invoke-Aio launch --fresh
try {
    Invoke-Aio command app.palette_commands | Out-Null
    Invoke-Aio type 'Split Right' | Out-Null
    Assert-Value (Read-State)['palette.item'] 'pane.split_right' 'command is searchable'
    $state = Read-State
    $list = $state['palette.list'] -split ','
    $scale = [double] $state['palette.row_height'] / 42
    $x = [double] $list[0] + [double] $list[2] - 100 * $scale
    $y = [double] $list[1] + [double] $state['palette.row_height'] / 2
    Invoke-Aio mouse click "$([int]$x),$([int]$y)" --px | Out-Null
    Assert-Value (Read-State)['palette.edit'] 'Shortcut' 'shortcut control opens alternatives'
    Invoke-Aio capture --out (Join-Path $repo 'build/palette-shortcut-list.png') | Out-Null
    Invoke-Aio key Esc | Out-Null
    Assert-Value (Read-State)['palette.edit'] 'None' 'Escape closes only shortcut editing'
    Assert-Value (Read-State)['palette.open'] 'true' 'palette remains open'

    Invoke-Aio key Ctrl+Enter Enter Ctrl+C | Out-Null
    Invoke-Aio capture --out (Join-Path $repo 'build/palette-shortcut-capture.png') | Out-Null
    # Ctrl+Shift+C belongs to Copy: recording names it, and Enter opens the conflict chain.
    $before = [IO.File]::ReadAllText($path)
    Invoke-Aio key Ctrl+Shift+C | Out-Null
    Assert-Value (Read-State)['palette.used_by'] 'Used by Copy' 'recording names the owner'
    Invoke-Aio key Enter | Out-Null
    Assert-Value (Read-State)['palette.edit'] 'Chain' 'conflicting shortcut opens the chain'
    Assert-Value ([IO.File]::ReadAllText($path)) $before 'conflict preserves the settings file'
    Invoke-Aio key Esc | Out-Null
    Assert-Value (Read-State)['palette.edit'] 'None' 'Escape drops the chain'
    Invoke-Aio key Ctrl+Enter Enter Ctrl+Alt+F9 Enter | Out-Null
    Assert-Value (Read-State)['palette.value'] 'Ctrl+Alt+F9' 'shortcut saves and applies live'
    Assert-Value (Read-State)['palette.edit'] 'None' 'saving ends capture'
    Assert-Value (Read-State)['settings.open'] 'false' 'editing never opens Settings'
    Assert-Value (Read-State)['palette.open'] 'true' 'saving keeps the palette open'
    if ([IO.File]::ReadAllText($path) -notmatch '(?m)^keys\.pane\.split_right = Ctrl\+Alt\+F9\r?$') {
        throw 'Saved shortcut did not reach the file.'
    }
    Invoke-Aio capture --out (Join-Path $repo 'build/palette-shortcut-saved.png') | Out-Null

    # Add a second alternative, then remove it without replacing the first.
    Invoke-Aio key Ctrl+Enter Down Enter Ctrl+Alt+F10 Enter | Out-Null
    Assert-Value (Read-State)['palette.value'] 'Ctrl+Alt+F9, Ctrl+Alt+F10' 'Add shortcut preserves alternatives'
    Invoke-Aio capture --out (Join-Path $repo 'build/shortcut-summary-palette.png') | Out-Null
    Invoke-Aio key Ctrl+Enter | Out-Null
    Invoke-Aio capture --out (Join-Path $repo 'build/shortcut-summary-palette-menu.png') | Out-Null
    Invoke-Aio key Esc Esc | Out-Null
    Invoke-Aio command settings.open | Out-Null
    Invoke-Aio type 'Split Right' | Out-Null
    Assert-Value (Read-State)['settings.key'] 'keys.pane.split_right' 'Settings finds the same shortcut'
    Assert-Value (Read-State)['settings.value'] 'Ctrl+Alt+F9, Ctrl+Alt+F10' 'Settings retains the full value'
    Invoke-Aio capture --out (Join-Path $repo 'build/shortcut-summary-settings.png') | Out-Null
    Invoke-Aio key Tab | Out-Null
    Assert-Value (Read-State)['settings.popup'] 'Shortcuts' 'Settings opens the full alternatives list'
    Invoke-Aio capture --out (Join-Path $repo 'build/shortcut-summary-settings-menu.png') | Out-Null
    Invoke-Aio key Esc | Out-Null
    Invoke-Aio command app.palette_commands | Out-Null
    Invoke-Aio type 'Split Right' | Out-Null
    Invoke-Aio key Ctrl+Enter Down Delete | Out-Null
    Assert-Value (Read-State)['palette.value'] 'Ctrl+Alt+F9' 'Delete removes only the chosen alternative'

    # The command row keeps the same reset button as Settings controls.
    $resetX = [double] $list[0] + [double] $list[2] - 21 * $scale
    Invoke-Aio mouse click "$([int]$resetX),$([int]$y)" --px | Out-Null
    Assert-Value (Read-State)['palette.value'] 'Ctrl+Shift+O' 'reset restores the default shortcut'
    Invoke-Aio key Esc Ctrl+Shift+O | Out-Null
    Invoke-Aio expect state 'panes.count=2' | Out-Null
    Write-Output 'PASS restored shortcut still executes its command'
} finally {
    & $ctl --name $name stop | Write-Output
}
