[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'close-confirm'
$directory = Join-Path $repo "build/verify/$name"
$path = Join-Path $directory 'settings.ini'
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}
function Read-State {
    $lines = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect state.' }
    $state = @{}
    foreach ($line in $lines) { $pair = $line -split '=', 2; $state[$pair[0]] = $pair[1].Trim('"') }
    return $state
}
function Assert-Equal($Actual, $Expected, [string] $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Shot([string] $Label) {
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Shot (Join-Path $directory "$Label.png") -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}
function Tab-Point([double] $Index) {
    $width = [double](Read-State)['tabs.width']
    return "$([int]($width*($Index-0.5))),20"
}
# Mirrors ui.confirm_layout so the journey clicks the dialog's real buttons.
function Button-Point([string] $Button) {
    $s = Read-State
    $size = $s['window.size'] -split 'x'
    $width, $height, $scale = [double]$size[0], [double]$size[1], [double]$s['window.scale']
    $panelWidth = [math]::Min(380*$scale, $width-32*$scale)
    $x = ($width-$panelWidth)/2
    $y = [math]::Max(24*$scale, $height*0.22)
    $buttonY = $y+150*$scale-16*$scale-15*$scale
    $accept = $x+$panelWidth-16*$scale-48*$scale
    if ($Button -eq 'cancel') { return "$([int]($accept-104*$scale)),$([int]$buttonY)" }
    return "$([int]$accept),$([int]$buttonY)"
}
function Open-Split-Tab {
    Invoke-Aio command tab.new
    Invoke-Aio command pane.split_right
    Invoke-Aio wait text 'PS '
}
Invoke-Aio launch --fresh
try {
    Invoke-Aio wait text 'PS '
    Invoke-Aio command pane.split_right
    Invoke-Aio wait text 'PS '
    Invoke-Aio command tab.new
    Invoke-Aio command tab.select_1
    Invoke-Aio key Ctrl+Shift+W
    $state = Read-State
    Assert-Equal $state['confirm.open'] true 'closing a split tab asks first'
    Assert-Equal $state['confirm.title'] 'Close this tab and its 2 panes?' 'question names the pane count'
    Start-Sleep -Milliseconds 200
    Shot dark
    Invoke-Aio type 'stray'
    Invoke-Aio key Esc
    $state = Read-State
    Assert-Equal $state['confirm.open'] false 'Escape cancels'
    Assert-Equal $state['tabs.count'] 2 'cancel keeps the tab'
    Assert-Equal $state['panes.count'] 2 'cancel keeps both panes'
    Invoke-Aio expect no-text stray
    Write-Output 'PASS keys typed while asking never reach the shell'
    Invoke-Aio key Ctrl+Shift+W Tab Enter
    Assert-Equal (Read-State)['tabs.count'] 2 'Tab then Enter chooses Cancel'
    Invoke-Aio key Ctrl+Shift+W Enter
    Assert-Equal (Read-State)['tabs.count'] 1 'Enter confirms the close'
    Invoke-Aio command tab.new
    Invoke-Aio key Ctrl+Shift+W
    $state = Read-State
    Assert-Equal $state['confirm.open'] false 'a single-pane tab closes without asking'
    Assert-Equal $state['tabs.count'] 1 'single-pane close completed'

    Open-Split-Tab
    Invoke-Aio mouse click (Tab-Point 2) --button middle --px
    Assert-Equal (Read-State)['confirm.open'] true 'middle click on a split tab asks'
    Invoke-Aio mouse click '20,600' --px
    $state = Read-State
    Assert-Equal $state['confirm.open'] false 'clicking outside the dialog cancels'
    Assert-Equal $state['tabs.count'] 2 'outside click keeps the tab'
    Invoke-Aio mouse click (Tab-Point 2) --button middle --px
    Invoke-Aio mouse click (Button-Point cancel) --px
    Assert-Equal (Read-State)['tabs.count'] 2 'Cancel button keeps the tab'
    Invoke-Aio mouse click (Tab-Point 2) --button middle --px
    Invoke-Aio mouse down (Button-Point accept) --px
    Invoke-Aio mouse up '20,600' --px
    $state = Read-State
    Assert-Equal $state['tabs.count'] 2 'releasing away from Close does not close'
    Assert-Equal $state['confirm.open'] true 'the question stays after a cancelled press'
    Invoke-Aio mouse click (Button-Point accept) --px
    Assert-Equal (Read-State)['tabs.count'] 1 'Close button closes the tab'

    Open-Split-Tab
    Invoke-Aio command tab.new
    Invoke-Aio command tab.select_2
    Invoke-Aio mouse click (Tab-Point 3) --px --mods Ctrl
    Invoke-Aio key Ctrl+Shift+W
    Assert-Equal (Read-State)['confirm.title'] 'Close 2 tabs with 3 panes?' 'a selected group names every pane'
    Shot group
    Invoke-Aio key Enter
    Assert-Equal (Read-State)['tabs.count'] 1 'confirming closes the whole group'

    [IO.File]::AppendAllText($path, "`ntheme.mode = light`n")
    Invoke-Aio command settings.reload
    Open-Split-Tab
    Invoke-Aio key Ctrl+Shift+W
    Start-Sleep -Milliseconds 200
    Shot light
    Invoke-Aio key Esc
    [IO.File]::AppendAllText($path, "`ntab.confirm_close = false`n")
    Invoke-Aio command settings.reload
    Invoke-Aio key Ctrl+Shift+W
    $state = Read-State
    Assert-Equal $state['confirm.open'] false 'the setting turns the question off'
    Assert-Equal $state['tabs.count'] 1 'split tab closes immediately when off'
    Write-Output 'PASS multi-pane tab close confirmation'
} finally {
    & $ctl --name $name stop | Out-Null
}
