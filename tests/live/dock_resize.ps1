param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'dock-resize'
$data = Join-Path $repo "build/verify/$name"
function Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    return $result
}
function State {
    $s = @{}
    foreach ($line in (Aio state)) {
        $pair = $line -split '=', 2
        $s[$pair[0]] = $pair[1].Trim('"')
    }
    return $s
}
function Rect($s, $key) { return @($s[$key] -split ',' | ForEach-Object { [double]$_ }) }
function Equal($actual, $expected, $label) {
    if ("$actual" -ne "$expected") { throw "$label expected $expected, observed $actual" }
    Write-Output "PASS $label"
}
Aio launch --fresh --size 140x40 | Out-Null
try {
    Add-Content -LiteralPath "$data/settings.ini" -Value "`nstatus.panel = true"
    Aio command settings.reload | Out-Null
    Aio command pane.split_down | Out-Null
    foreach ($orientation in @('horizontal', 'vertical')) {
        if ((State)['tabs.orientation'] -ne $orientation) { Aio command view.tabs_orientation | Out-Null }
        foreach ($dpi in @(96, 144)) {
            Aio dpi $dpi | Out-Null
            foreach ($side in @('right', 'left')) {
                $s = State
                if ($s['activity.side'] -ne $side) {
                    $button = Rect $s 'activity.side_button'
                    $point = "$([int]($button[0]+$button[2]/2)),$([int]($button[1]+$button[3]/2))"
                    Aio mouse click $point --px | Out-Null
                }
                $s = State
                Equal $s['activity.side'] $side "$orientation $dpi DPI side toggle"
                if (-not (Select-String -LiteralPath "$data/settings.ini" -SimpleMatch "status.panel_side = $side" -Quiet)) {
                    # The default right side need not have an explicit setting until the first toggle.
                    if ($side -ne 'right') { throw 'side toggle was not persisted' }
                }
                $panel = Rect $s 'activity.rect'
                $scale = [double]$s['window.scale']
                $x = [int]$(if ($side -eq 'left') { $panel[0]+$panel[2] } else { $panel[0] })
                $y = [int]($panel[1]+80*$scale)
                $end = [int]($x + 24*$scale)
                Aio mouse move "$x,$y" --px | Out-Null
                Equal (State)['pointer.shape'] resize_horizontal "$orientation $side $dpi DPI cursor"
                Aio mouse down "$x,$y" --px | Out-Null
                Equal (State)['dividers.dragging'] 1 "$orientation $side shared divider starts"
                Aio mouse move "$end,$y" --px | Out-Null
                $change = $(if ($side -eq 'left') { 24*$scale } else { -24*$scale })
                Equal ((Rect (State) 'activity.rect')[2]-$panel[2]) $change "$orientation $side width follows"
                Aio mouse up "$end,$y" --px | Out-Null
                Equal (State)['dividers.dragging'] 0 'release finishes shared resize'
                Aio capture --out "$data/$orientation-$side-$dpi.png" | Out-Null
            }
        }
    }
    $s = State
    $rail = Rect $s 'rail.rect'
    $pane = Rect $s "pane.$($s['panes.focused']).rect"
    $x = [int]($rail[0]+$rail[2])
    $topEnd = $pane[1]
    foreach ($key in @($s.Keys)) {
        if ($key -match '^pane\.[0-9]+\.rect$') {
            $candidate = Rect $s $key
            if ($candidate[1] -lt $pane[1]) { $topEnd = $candidate[1]+$candidate[3] }
        }
    }
    $y = [int](($topEnd+$pane[1])/2)
    Aio mouse move "$x,$y" --px | Out-Null
    Equal (State)['pointer.shape'] resize_all 'rail and top/bottom split junction cursor'
    Aio mouse down "$x,$y" --px | Out-Null
    Equal (State)['dividers.dragging'] 2 'junction starts both dividers'
    $endX, $endY = ($x+30), ($y+30)
    Aio mouse move "$endX,$endY" --px | Out-Null
    Equal ((Rect (State) 'rail.rect')[2]-$rail[2]) 30 'junction moves rail'
    $delta = (Rect (State) "pane.$($s['panes.focused']).rect")[1]-$pane[1]
    if ([math]::Abs($delta-30) -gt 1) { throw "pane split did not follow junction: $delta" }
    Write-Output 'PASS junction moves pane split'
    Aio mouse up "$endX,$endY" --px | Out-Null
} finally { & $ctl --name $name stop | Out-Null }
