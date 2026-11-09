[CmdletBinding()]
param([string] $Name = 'linked-window')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$evidence = Join-Path $repo "build/verify/$Name-evidence"
New-Item -ItemType Directory -Force $evidence | Out-Null

function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out
}
function Get-State {
    $values = @{}
    foreach ($line in (Invoke-Aio state)) {
        $pair = $line -split '=', 2
        if ($pair.Count -eq 2) { $values[$pair[0]] = $pair[1].Trim('"') }
    }
    $values
}
function Await([scriptblock] $Condition, [string] $What) {
    $until = [DateTime]::UtcNow.AddSeconds(8)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $until)
    throw "Timed out waiting: $What"
}
function Get-LinkedId {
    $s = Get-State
    for ($i = 1; $i -le [int]$s['windows.count']; $i++) {
        if ($s["window.$i.linked"] -eq 'true') { return $s["window.$i.id"] }
    }
    return $null
}
# The app shows an ordinary window once it is past preparing, and a linked one while its tab is on screen.
function Get-Visible {
    $s = Get-State
    $count = 0
    for ($i = 1; $i -le [int]$s['windows.count']; $i++) {
        $shown = $s["window.$i.preparing"] -ne 'true'
        if ($s["window.$i.linked"] -eq 'true') { $shown = $s["window.$i.link_shown"] -eq 'true' }
        if ($shown) { $count++ }
    }
    $count
}
function Await-Visible([int] $Count, [string] $What) {
    Await { (Get-Visible) -eq $Count } "$What ($Count visible windows)"
    Write-Output "PASS $What"
}
function Save-Shot([string] $Id, [string] $File) {
    Invoke-Aio window select $Id | Out-Null
    Invoke-Aio capture --out (Join-Path $evidence $File) | Out-Null
}

$settings = Join-Path $evidence 'settings.ini'
Set-Content -LiteralPath $settings -Value "cursor.blink = false`ntab.confirm_close = false"
Invoke-Aio launch --fresh --settings $settings | Out-Null
try {
    Invoke-Aio wait text 'PS ' | Out-Null

    # A lone pane cannot leave: the tab would have nothing in its main window.
    Invoke-Aio command pane.linked_window | Out-Null
    Invoke-Aio expect state windows.count=1 | Out-Null
    Write-Output 'PASS a lone pane stays put'

    Invoke-Aio command pane.split_right | Out-Null
    Invoke-Aio expect state panes.count=2 | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio run "'linked-marker-' + (40 + 2)" | Out-Null
    Invoke-Aio wait text 'linked-marker-42' | Out-Null
    $hostId = (Get-State)['window.1.id']

    Invoke-Aio command pane.linked_window | Out-Null
    Invoke-Aio expect state windows.count=2 | Out-Null
    Invoke-Aio expect state panes.count=1 | Out-Null
    Await-Visible 2 'linking opens a second window'
    $linkedId = Get-LinkedId
    if (-not $linkedId) { throw 'No linked window in state.' }

    # The pane in the window is the running one: its output is there, and input reaches it.
    Invoke-Aio window select $linkedId | Out-Null
    Invoke-Aio expect text 'linked-marker-42' | Out-Null
    Invoke-Aio run "'typed-' + (40 + 3)" | Out-Null
    Invoke-Aio wait text 'typed-43' | Out-Null
    Write-Output 'PASS the linked window shows the running pane and takes input'
    Save-Shot $hostId 'host.png'
    Save-Shot $linkedId 'linked.png'

    Invoke-Aio window select $hostId | Out-Null
    Invoke-Aio command tab.new | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Await-Visible 1 'another tab hides the linked window'
    Invoke-Aio command tab.select_1 | Out-Null
    Await-Visible 2 'its tab brings the linked window back'
    Invoke-Aio window select $linkedId | Out-Null
    Invoke-Aio expect text 'typed-43' | Out-Null
    Write-Output 'PASS the pane kept running output across the hide'

    # Hiding and showing must not lose a maximized window, which is how a second monitor gets used.
    Invoke-Aio window select $linkedId | Out-Null
    Invoke-Aio window maximize | Out-Null
    Await { (Get-State)['window.maximized'] -eq 'true' } 'the linked window to maximize'
    $maximizedSize = (Get-State)['window.size']
    Invoke-Aio window select $hostId | Out-Null
    Invoke-Aio command tab.select_2 | Out-Null
    Await-Visible 1 'a maximized linked window hides'
    Invoke-Aio command tab.select_1 | Out-Null
    Await-Visible 2 'a maximized linked window returns'
    Invoke-Aio window select $linkedId | Out-Null
    Await { (Get-State)['window.maximized'] -eq 'true' } 'the linked window to stay maximized'
    $size = (Get-State)['window.size']
    if ($size -ne $maximizedSize) { throw "Returned at $size, not the maximized $maximizedSize." }
    Write-Output 'PASS the window stays maximized across a hide'

    # A tab command from the linked window runs on the tabs, which live in the host.
    Invoke-Aio command tab.select_2 | Out-Null
    Await-Visible 1 'a tab command from the linked window switches the host'
    Invoke-Aio window select $hostId | Out-Null
    Invoke-Aio command tab.select_1 | Out-Null
    Await-Visible 2 'the tab returns once more'

    # Hiding the host takes its linked window along; reopening restores both.
    Invoke-Aio command app.hide_to_tray | Out-Null
    Await-Visible 0 'hiding to the tray hides the linked window'
    Invoke-Aio tray open | Out-Null
    Await-Visible 2 'reopening restores the linked window'

    # Closing the window keeps the pane: it returns to its split with its output.
    $linkedId = Get-LinkedId
    Invoke-Aio window select $linkedId | Out-Null
    Invoke-Aio window close | Out-Null
    Await { (Get-State)['windows.count'] -eq '1' } 'closing the linked window'
    Invoke-Aio window select (Get-State)['window.1.id'] | Out-Null
    Invoke-Aio expect state panes.count=2 | Out-Null
    # The close arrived without OS focus on the window, so the host keeps the pane it had focused.
    Invoke-Aio command pane.focus_next | Out-Null
    Invoke-Aio expect text 'typed-43' | Out-Null
    Write-Output 'PASS closing the linked window returns the pane to its split'

    # The command returns the pane too.
    Invoke-Aio command pane.linked_window | Out-Null
    Invoke-Aio expect state windows.count=2 | Out-Null
    $linkedId = Get-LinkedId
    Invoke-Aio window select $linkedId | Out-Null
    Invoke-Aio command pane.linked_window | Out-Null
    Await { (Get-State)['windows.count'] -eq '1' } 'the toggle returning the pane'
    Write-Output 'PASS the command toggles both ways'

    # A linked window takes splits of its own, which follow the tab with it.
    $hostId = (Get-State)['window.1.id']
    Invoke-Aio command pane.linked_window | Out-Null
    Invoke-Aio expect state windows.count=2 | Out-Null
    $linkedId = Get-LinkedId
    Invoke-Aio window select $linkedId | Out-Null
    Invoke-Aio command pane.split_down | Out-Null
    Invoke-Aio expect state panes.count=2 | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio run "'split-marker-' + (40 + 4)" | Out-Null
    Invoke-Aio wait text 'split-marker-44' | Out-Null
    Save-Shot $linkedId 'linked-split.png'
    Invoke-Aio window select $hostId | Out-Null
    Invoke-Aio expect state panes.count=1 | Out-Null
    Invoke-Aio command tab.select_2 | Out-Null
    Await-Visible 1 'another tab hides a split linked window'
    Invoke-Aio command tab.select_1 | Out-Null
    Await-Visible 2 'its tab brings the split linked window back'
    Invoke-Aio window select $linkedId | Out-Null
    Invoke-Aio expect text 'split-marker-44' | Out-Null
    Write-Output 'PASS a linked window holds its own split'

    # The toggle returns the focused pane and keeps the other in the window.
    Invoke-Aio command pane.linked_window | Out-Null
    Invoke-Aio expect state windows.count=2 | Out-Null
    Invoke-Aio expect state panes.count=1 | Out-Null
    Invoke-Aio window select $hostId | Out-Null
    Invoke-Aio expect state panes.count=2 | Out-Null
    Write-Output 'PASS returning one pane keeps the rest in the window'

    # Closing the window returns everything still in it, split included.
    Invoke-Aio window select $linkedId | Out-Null
    Invoke-Aio command pane.split_down | Out-Null
    Invoke-Aio expect state panes.count=2 | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio window select $linkedId | Out-Null
    Invoke-Aio window close | Out-Null
    Await { (Get-State)['windows.count'] -eq '1' } 'closing the split linked window'
    Invoke-Aio window select $hostId | Out-Null
    Invoke-Aio expect state panes.count=4 | Out-Null
    Write-Output 'PASS closing a split linked window returns every pane'
    Invoke-Aio command pane.close | Out-Null
    Invoke-Aio command pane.close | Out-Null
    Invoke-Aio expect state panes.count=2 | Out-Null

    # The shell exiting closes the pane, and its window with it.
    Invoke-Aio command pane.linked_window | Out-Null
    Invoke-Aio expect state windows.count=2 | Out-Null
    $linkedId = Get-LinkedId
    Invoke-Aio window select $linkedId | Out-Null
    Invoke-Aio run 'exit' | Out-Null
    Await { (Get-State)['windows.count'] -eq '1' } 'the exited pane closing its window'
    Invoke-Aio expect state panes.count=1 | Out-Null
    Write-Output 'PASS a shell exit closes the linked window'

    # The link and the window's place survive a restart.
    Invoke-Aio command pane.split_right | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio command pane.linked_window | Out-Null
    Invoke-Aio expect state windows.count=2 | Out-Null
    $linkedId = Get-LinkedId
    Invoke-Aio window select $linkedId | Out-Null
    Invoke-Aio command pane.split_down | Out-Null
    Invoke-Aio expect state panes.count=2 | Out-Null
    Invoke-Aio window move '220,160' | Out-Null
    $origin = (Get-State)['window.origin']
    Invoke-Aio window select (Get-State)['window.1.id'] | Out-Null
    Start-Sleep -Milliseconds 2500
    Invoke-Aio stop | Out-Null
    Invoke-Aio launch --keep-layout --settings $settings | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Await { (Get-Visible) -eq 2 } 'the restored linked window'
    $linkedId = Get-LinkedId
    if (-not $linkedId) { throw 'The link did not survive the restart.' }
    Invoke-Aio window select $linkedId | Out-Null
    $restored = (Get-State)['window.origin']
    if ($restored -ne $origin) { throw "Restored at $restored, not $origin." }
    Invoke-Aio expect state panes.count=2 | Out-Null
    Write-Output 'PASS the link, its split and the window position survive a restart'
    Write-Output 'PASS linked window'
} finally {
    & $ctl --name $Name stop | Out-Null
}
