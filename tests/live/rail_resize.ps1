param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'rail-resize'

function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
}
function Read-State {
    $result = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect rail state.' }
    $state = @{}
    foreach ($line in $result) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}
function Rect($State, $Key) {
    return @($State[$Key] -split ',' | ForEach-Object { [double]$_ })
}
function Assert-Value($Actual, $Expected, $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}

Invoke-Aio launch --fresh --size 140x36
try {
    Invoke-Aio command view.tabs_orientation
    Invoke-Aio expect state tabs.orientation=vertical
    foreach ($dpi in @(96, 144)) {
        Invoke-Aio dpi $dpi
        Invoke-Aio resize 140x36
        $before = Read-State
        $scale = [double]$before['window.scale']
        $rail = Rect $before 'rail.rect'
        $pane = Rect $before "pane.$($before['panes.focused']).rect"
        $x = [int]($rail[0] + $rail[2])
        $y = [int]($rail[1] + 80*$scale)
        $endX = [int]($x + 64*$scale)
        Invoke-Aio mouse move "$x,$y" --px
        Assert-Value (Read-State)['pointer.shape'] resize_horizontal "rail border cursor at $dpi DPI"
        Invoke-Aio mouse down "$x,$y" --px
        Assert-Value (Read-State)['rail.resizing'] true "resize starts at $dpi DPI"
        Invoke-Aio mouse move "$endX,$y" --px
        $after = Read-State
        $resized = Rect $after 'rail.rect'
        $content = Rect $after "pane.$($after['panes.focused']).rect"
        Assert-Value ($resized[2] - $rail[2]) (64*$scale) "rail follows drag at $dpi DPI"
        Assert-Value ($content[0] - $pane[0]) (64*$scale) "content follows border at $dpi DPI"
        $outsideY = [int](($before['window.size'] -split 'x')[1]) + 20
        Invoke-Aio mouse up "$endX,$outsideY" --px
        Assert-Value (Read-State)['rail.resizing'] false "outside release ends resize at $dpi DPI"
        Invoke-Aio command view.tabs_orientation
        Invoke-Aio command view.tabs_orientation
        Assert-Value ((Rect (Read-State) 'rail.rect')[2]) $resized[2] "orientation keeps width at $dpi DPI"
        Invoke-Aio mouse down "$endX,$y" --px
        Invoke-Aio focus out
        Assert-Value (Read-State)['rail.resizing'] false "focus loss cancels resize at $dpi DPI"
        Invoke-Aio mouse up "$endX,$y" --px
        Invoke-Aio focus in
    }
    Invoke-Aio resize 60x30
    Invoke-Aio expect state rail.visible=false
    Invoke-Aio command view.tabs_rail
    Invoke-Aio expect state rail.overlay=true
    $before = Read-State
    $rail = Rect $before 'rail.rect'
    $paneKey = "pane.$($before['panes.focused']).rect"
    $x = [int]($rail[0] + $rail[2])
    $y = [int]($rail[1] + 80)
    Invoke-Aio mouse drag "$x,$y" '180,150' --px
    Assert-Value (Read-State)[$paneKey] $before[$paneKey] 'overlay resize keeps content geometry'
    Invoke-Aio command view.tabs_rail
    Invoke-Aio resize 140x36
    Invoke-Aio command app.command_palette
    Invoke-Aio type 't:'
    Invoke-Aio expect state palette.mode=tabs
    Invoke-Aio key Esc
} finally {
    & $ctl --name $name stop | Out-Null
}
