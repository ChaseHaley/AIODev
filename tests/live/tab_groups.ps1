[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'tab-groups'
$directory = Join-Path $repo "build/verify/$name"
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}
function Tab-X($State) { if (-not $State.ContainsKey('tabs.x')) { throw 'State lacks tabs.x; the tab strip offset is unknown.' }; return [double]$State['tabs.x'] }
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
function Assert-True([bool] $Condition, [string] $Label) {
    if (-not $Condition) { throw "$Label failed" }
    Write-Output "PASS $Label"
}
function Point([double] $Index) { $s = Read-State; return "$([int]((Tab-X $s)+[double]$s['tabs.width']*($Index-0.5))),20" }
function Click-Tab([int] $Index, [string] $Modifiers = '') {
    $point = Point $Index
    if ($Modifiers) { Invoke-Aio mouse click $point --px --mods $Modifiers }
    else { Invoke-Aio mouse click $point --px }
}
function Order { $s = Read-State; return ((1..[int]$s['tabs.count'] | ForEach-Object { $s["tab.$_.id"] }) -join ',') }
function Marked {
    $s = Read-State
    return ((1..[int]$s['tabs.count'] | Where-Object { $s["tab.$_.marked"] -eq 'true' }) -join ',')
}
function Shot([string] $Label) {
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Shot (Join-Path $directory "$Label.png") -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}
Invoke-Aio launch --fresh
try {
    $session = (Read-State)['session.id']
    Invoke-Aio run 'Write-Output GROUP_MARKER'
    foreach ($i in 2..6) { Invoke-Aio command tab.new }
    Invoke-Aio wait text 'PS '
    Invoke-Aio command tab.select_1
    Click-Tab 3 Ctrl
    Assert-Equal (Marked) '1,3' 'Ctrl adds a noncontiguous tab'
    Click-Tab 5 Shift
    Assert-Equal (Marked) '3,4,5' 'Shift replaces selection with anchored range'
    Click-Tab 2 Ctrl+Shift
    Assert-Equal (Marked) '2,3,4,5' 'Ctrl+Shift adds an anchored range'
    Click-Tab 4 Ctrl
    Assert-Equal (Marked) '2,3,5' 'Ctrl removes only one selected tab'
    Click-Tab 5
    Assert-Equal (Marked) '5' 'plain click collapses selection on release'
    Invoke-Aio command tab.select_1
    Click-Tab 3 Ctrl
    $before = Read-State
    $original = Order
    $width = [double]$before['tabs.width']
    $tabX = Tab-X $before
    $start = Point 1
    $end = "$([int]($tabX+$width*5.6)),20"
    Invoke-Aio mouse down $start --px
    Invoke-Aio mouse move $end --px
    Invoke-Aio key Esc
    Invoke-Aio mouse up $end --px
    Assert-Equal (Order) $original 'cancel restores noncontiguous original order'
    Assert-Equal (Marked) '1,3' 'cancel preserves noncontiguous selection'
    Start-Sleep -Milliseconds 220
    Invoke-Aio mouse down $start --px
    $middle = [int]($tabX+$width*3.8)
    Invoke-Aio mouse move "$middle,20" --px
    $attached = Read-State
    $grabbed = 1..6 | Where-Object { $attached["tab.$_.id"] -eq '1' }
    Assert-True ([math]::Abs([double]$attached["tab.$grabbed.position"]*$width+$width/2-($middle-$tabX)) -lt 1) 'grabbed tab follows pointer between slots'
    Invoke-Aio mouse move $end --px
    $moving = Read-State
    Assert-Equal $moving['tabs.dragging'] true 'group drag owns the pointer'
    Assert-Equal (Order) '2,4,5,6,1,3' 'group moves in original strip order'
    Assert-Equal $moving['session.id'] $session 'group drag keeps grabbed runtime active'
    if ($moving['ui.animations'] -eq 'true') {
        $fractional = 1..6 | Where-Object { [math]::Abs([double]$moving["tab.$_.position"]-($_-1)) -gt 0.001 }
        Assert-True (@($fractional).Count -gt 0) 'displaced tabs slide through intermediate positions'
    }
    Shot group-drag
    Invoke-Aio mouse up $end --px
    Start-Sleep -Milliseconds 220
    $after = Read-State
    foreach ($index in 1..6) {
        $id = $after["tab.$index.id"]
        $oldIndex = 1..6 | Where-Object { $before["tab.$_.id"] -eq $id }
        Assert-Equal $after["tab.$index.pane.0.session"] $before["tab.$oldIndex.pane.0.session"] "runtime retained for tab $id"
        Assert-Equal $after["tab.$index.position"] ($index-1) 'tab settles exactly in its slot'
    }
    Assert-Equal (Marked) '5,6' 'selection follows group identity'
    Invoke-Aio expect text GROUP_MARKER
    $order = Order
    $start = Point 5
    $end = Point 1
    Invoke-Aio mouse down $start --px
    Invoke-Aio mouse move $end --px
    Invoke-Aio key Esc
    Invoke-Aio mouse up $end --px
    Assert-Equal (Order) $order 'Escape restores the complete group order'
    Start-Sleep -Milliseconds 220
    Invoke-Aio mouse down (Point 5) --px
    Invoke-Aio mouse move (Point 1) --px
    Invoke-Aio focus out
    Invoke-Aio mouse up (Point 1) --px
    Assert-Equal (Order) $order 'focus loss restores group order'
    Start-Sleep -Milliseconds 220
    Shot selected-group
    $s = Read-State
    $width, $tabX = [double]$s['tabs.width'], (Tab-X $s)
    Invoke-Aio mouse click "$([int]($tabX+$width*6-17)),20" --px
    Assert-Equal (Order) '2,4,5,6' 'X on a selected tab closes the group only'
    Assert-Equal (Read-State)['sessions.count'] 4 'group close cleans up only selected runtimes'
    Click-Tab 1
    Click-Tab 3 Ctrl
    Invoke-Aio key Ctrl+Shift+W
    Assert-Equal (Read-State)['tabs.count'] 2 'keyboard close acts on selected tabs'
    Assert-Equal (Read-State)['sessions.count'] 2 'keyboard group close cleans up sessions'
    Start-Sleep -Milliseconds 350
    $frames = (Read-State)['frames.presented']
    Start-Sleep -Milliseconds 400
    Assert-Equal (Read-State)['frames.presented'] $frames 'settled reordering produces no idle frames'
    Invoke-Aio command tab.new
    $s = Read-State
    $survivors = @($s['tab.1.id'], $s['tab.3.id']) -join ','
    Invoke-Aio command tab.select_2
    Invoke-Aio type 'Start-Sleep -Milliseconds 1200; exit'
    Invoke-Aio key Enter
    Invoke-Aio command tab.select_1
    Click-Tab 3 Ctrl
    $s = Read-State
    $drop = "$([int]((Tab-X $s)+[double]$s['tabs.width']*2.6)),20"
    Invoke-Aio mouse down (Point 1) --px
    Invoke-Aio mouse move $drop --px
    Start-Sleep -Milliseconds 1500
    Invoke-Aio mouse up $drop --px
    Assert-Equal (Order) $survivors 'shell exit during group drag closes the correct tab after cancellation'
    Assert-Equal (Read-State)['tabs.dragging'] false 'shell exit cancels active group drag'
    Click-Tab 1
    Click-Tab 2 Shift
    Invoke-Aio key Ctrl+Shift+W
    Invoke-Aio expect state tabs.count=0
    Invoke-Aio expect state sessions.count=0
    Invoke-Aio expect state window.visible=false
    Invoke-Aio tray open
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state tabs.count=1
    Write-Output 'PASS closing the complete group releases the window and reopens a fresh session'
    Write-Output 'PASS tab multiselection, group actions and animation journey'
} finally {
    & $ctl --name $name stop | Out-Null
}
