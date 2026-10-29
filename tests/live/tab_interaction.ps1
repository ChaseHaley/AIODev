[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'tab-interaction'
$directory = Join-Path $repo "build/verify/$name-captures"

function Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}
function State {
    $state = @{}
    foreach ($line in (& $ctl --name $name state)) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect tab interaction state.' }
    return $state
}
function Equal($Actual, $Expected, $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Point($Rect) {
    $r = $Rect -split ','
    return "$([int]([double]$r[0] + [double]$r[2] / 2)),$([int]([double]$r[1] + [double]$r[3] / 2))"
}
function Tab-Point([int] $Index, [switch] $Close) {
    $s = State
    $suffix = if ($s['tabs.orientation'] -eq 'horizontal') {
        if ($Close) { 'strip_close' } else { 'strip_rect' }
    } else {
        if ($Close) { 'close' } else { 'rect' }
    }
    return Point $s["tab.$Index.$suffix"]
}
function Marked {
    $s = State
    return ((1..[int]$s['tabs.count'] | Where-Object { $s["tab.$_.marked"] -eq 'true' }) -join ',')
}
function Order {
    $s = State
    return ((1..[int]$s['tabs.count'] | ForEach-Object { $s["tab.$_.id"] }) -join ',')
}

New-Item -ItemType Directory -Force $directory | Out-Null
foreach ($orientation in @('horizontal', 'vertical')) {
    Aio launch --fresh
    try {
        if ((State)['tabs.orientation'] -ne $orientation) { Aio command view.tabs_orientation }
        Aio command tab.new
        Aio command tab.new
        Aio command tab.select_1
        Aio mouse click (Tab-Point 2) --px --mods Ctrl
        Equal (Marked) '1,2' "$orientation Ctrl adds a tab"
        Aio mouse click (Tab-Point 3) --px --mods Shift
        Equal (Marked) '2,3' "$orientation Shift uses the selection anchor"
        Aio mouse click (Tab-Point 1) --px --mods Ctrl+Shift
        Equal (Marked) '1,2,3' "$orientation Ctrl+Shift adds a range"
        Aio mouse click (Tab-Point 2) --px --mods Ctrl
        Equal (Marked) '1,3' "$orientation Ctrl removes a tab"
        Aio mouse click (Tab-Point 1) --px --button right
        Equal (State)['tab_menu.open'] true "$orientation opens the tab context menu"
        Equal (Marked) '1,3' "$orientation context menu preserves the selected group"
        Aio key Esc
        Aio mouse click (Tab-Point 1) --px
        Equal (Marked) '1' "$orientation plain release collapses selection"
        $order = Order
        Aio mouse down (Tab-Point 1) --px
        Aio mouse move (Tab-Point 3) --px
        Equal (State)['tabs.dragging'] true "$orientation arms a real reorder drag"
        Aio focus out
        Aio mouse up (Tab-Point 3) --px
        Equal (Order) $order "$orientation focus cancellation restores tab order"
        Start-Sleep -Milliseconds 220
        Aio mouse down (Tab-Point 1 -Close) --px
        Aio mouse up (Tab-Point 2 -Close) --px
        Equal (State)['tabs.count'] 3 "$orientation mismatched release keeps the tabs"
        Aio mouse down (Tab-Point 1 -Close) --px
        Aio focus out
        Aio mouse up (Tab-Point 1 -Close) --px
        Equal (State)['tabs.count'] 3 "$orientation cancellation ignores a late close release"
        Aio mouse click (Tab-Point 2 -Close) --px
        Equal (State)['tabs.count'] 2 "$orientation matching release closes one tab"
        Aio mouse click (Tab-Point 2) --px --button middle
        Equal (State)['tabs.count'] 1 "$orientation middle click closes one tab"
        if ($orientation -eq 'vertical') {
            Aio resize 60x20
            Aio key Ctrl+Shift+B
            Equal (State)['rail.overlay'] true 'narrow rail opens as an overlay'
            Aio mouse down (Tab-Point 1) --px
            Equal (State)['rail.visible'] false 'overlay selection dismisses its rows'
            Aio mouse move '50,160' --px
            Equal (State)['tabs.dragging'] false 'dismissed overlay does not begin reorder'
            Aio mouse up '50,160' --px
            Aio resize 120x32
        }
        Equal (State)['tabs.orientation'] $orientation "capture uses actual $orientation placement"
        & (Join-Path $repo 'tools/win32.ps1') -Name $name -Frame -Shot (Join-Path $directory "$orientation.png") | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Tab interaction capture failed.' }
    } finally {
        & $ctl --name $name stop | Out-Null
    }
}
