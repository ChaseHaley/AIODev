param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'pointer-shapes'

function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
}
function Read-State {
    $result = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read pointer state.' }
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
function Assert-Move([double]$X, [double]$Y, [string]$Shape, [string]$Label) {
    $before = Read-State
    Invoke-Aio mouse move "$([int]$X),$([int]$Y)" --px
    $after = Read-State
    if ($after['pointer.shape'] -ne $Shape) {
        throw "$Label expected $Shape, observed $($after['pointer.shape'])"
    }
    if ([long]$after['pointer.updates'] - [long]$before['pointer.updates'] -gt 1) {
        throw "$Label changed cursor more than once during a move."
    }
    Write-Output "PASS $Label ($Shape, at most one cursor change)"
}

Invoke-Aio launch --fresh
try {
    Invoke-Aio command settings.open
    foreach ($dpi in @(96, 144)) {
        Invoke-Aio dpi $dpi
        $state = Read-State
        $scale = [double]$state['window.scale']
        $list = Rect $state 'settings.list_rect'
        $search = Rect $state 'settings.search_rect'
        foreach ($offset in 0..3) {
            Assert-Move ($list[0] - 8*$scale) ($list[1] + 40*$scale + $offset) arrow "Settings page at $dpi DPI"
        }
        Assert-Move ($search[0] + $search[2]/2) ($search[1] + $search[3]/2) text "Settings search at $dpi DPI"
        Assert-Move ($list[0] - 8*$scale) ($list[1] + 40*$scale) arrow "leave search at $dpi DPI"
    }
    Invoke-Aio command tab.close
    Invoke-Aio command app.command_palette
    Invoke-Aio type 't:'
    foreach ($dpi in @(96, 144)) {
        Invoke-Aio dpi $dpi
        $state = Read-State
        $scale = [double]$state['window.scale']
        $panel = Rect $state 'palette.panel'
        $chipX = $panel[0] + 34*$scale
        $chipY = $panel[1] + 40*$scale
        Assert-Move ($panel[0] + $panel[2] - 20*$scale) $chipY text "palette query at $dpi DPI"
        Assert-Move $chipX $chipY hand "t: dropdown chip at $dpi DPI"
        Invoke-Aio mouse click "$([int]$chipX),$([int]$chipY)" --px
        Assert-Move ($panel[0] + 50*$scale) ($panel[1] + 85*$scale) hand "mode menu row at $dpi DPI"
        Invoke-Aio key Esc
    }
    Invoke-Aio key Esc
    Invoke-Aio command tab.new
    Invoke-Aio command tab.select_1
    foreach ($orientation in @('horizontal', 'vertical')) {
        if ((Read-State)['tabs.orientation'] -ne $orientation) { Invoke-Aio command view.tabs_orientation }
        foreach ($dpi in @(96, 144)) {
            Invoke-Aio dpi $dpi
            $state = Read-State
            $prefix = $orientation -eq 'horizontal' ? 'strip_' : ''
            $selected = Rect $state "tab.1.$($prefix)rect"
            $close = Rect $state "tab.1.$($prefix)close"
            $other = Rect $state "tab.2.$($prefix)rect"
            $label = "$orientation tabs at $dpi DPI"
            Assert-Move ($selected[0] + 6) ($selected[1] + $selected[3]/2) arrow "selected tab body, $label"
            Assert-Move ($close[0] + $close[2]/2) ($close[1] + $close[3]/2) hand "selected tab close, $label"
            Assert-Move ($other[0] + 6) ($other[1] + $other[3]/2) hand "unselected tab, $label"
        }
    }
} finally {
    & $ctl --name $name stop | Out-Null
}
