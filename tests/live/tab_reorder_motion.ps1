[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'tab-reorder-motion'
$captures = Join-Path $repo "build/verify/$name-captures"

function Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    return $out
}
function State {
    $state = @{}
    foreach ($line in (Aio state)) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}
function Equal($Actual, $Expected, $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Near([double] $Actual, [double] $Expected, $Label) {
    if ([math]::Abs($Actual - $Expected) -gt 0.02) { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Rect($State, [int] $Index, $Orientation) {
    $suffix = if ($Orientation -eq 'horizontal') { 'strip_rect' } else { 'rect' }
    return @($State["tab.$Index.$suffix"].Split(',') | ForEach-Object { [double] $_ })
}
function Order($State) {
    return ((1..[int]$State['tabs.count'] | ForEach-Object { $State["tab.$_.id"] }) -join ',')
}

New-Item -ItemType Directory -Force $captures | Out-Null
foreach ($orientation in @('horizontal', 'vertical')) {
    Aio launch --fresh | Out-Null
    try {
        if ((State)['tabs.orientation'] -ne $orientation) { Aio command view.tabs_orientation | Out-Null }
        foreach ($i in 2..4) { Aio command tab.new | Out-Null }
        Aio command tab.select_1 | Out-Null
        foreach ($dpi in @(96, 144)) {
            Aio dpi $dpi | Out-Null
            Start-Sleep -Milliseconds 200
            $before = State
            $original = Order $before
            $r = Rect $before 1 $orientation
            $x, $y = [int]($r[0] + $r[2] / 2), [int]($r[1] + $r[3] / 2)
            $endX, $endY = $x, $y
            if ($orientation -eq 'horizontal') { $endX += [int](1.25 * $r[2]) }
            else { $endY += [int](1.25 * $r[3]) }
            Aio mouse down "$x,$y" --px | Out-Null
            Aio mouse move "$endX,$endY" --px | Out-Null
            $moving = State
            Equal $moving['tabs.dragging'] true "$orientation $dpi DPI drag is active"
            Equal $moving['tab.2.id'] $before['tab.1.id'] "$orientation $dpi DPI reorders by stable identity"
            $expected = if ($orientation -eq 'horizontal') { ($endX - $x) / $r[2] } else { ($endY - $y) / $r[3] }
            Near ([double]$moving['tab.2.position']) $expected "$orientation $dpi DPI follows fractional pointer movement"
            $moved = Rect $moving 2 $orientation
            $offset = if ($orientation -eq 'horizontal') { ($moved[0] - $r[0]) / $r[2] } else { ($moved[1] - $r[1]) / $r[3] }
            Near $offset $expected "$orientation $dpi DPI visible geometry follows the pointer"
            & (Join-Path $repo 'tools/win32.ps1') -Name $name -Shot (Join-Path $captures "$orientation-$dpi.png") -Frame | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
            Aio key Esc | Out-Null
            Aio mouse up "$endX,$endY" --px | Out-Null
            Equal (Order (State)) $original "$orientation $dpi DPI Escape restores original order"
            Start-Sleep -Milliseconds 220
            Aio mouse down "$x,$y" --px | Out-Null
            Aio mouse move "$endX,$endY" --px | Out-Null
            Aio mouse up "$endX,$endY" --px | Out-Null
            Start-Sleep -Milliseconds 220
            $settled = State
            Equal $settled['tab.2.id'] $before['tab.1.id'] "$orientation $dpi DPI release keeps the new order"
            foreach ($index in 1..4) {
                Near ([double]$settled["tab.$index.position"]) ($index - 1) "$orientation $dpi DPI tab $index settles"
            }
            Equal $settled['ui.animating'] false "$orientation $dpi DPI motion becomes idle"
        }
    } finally { Aio stop | Out-Null }
}
