[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'title-bar'
$directory = Join-Path $repo "build/verify/$name"
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}
function Tab-Point([int] $Index) {
    $s = Read-State
    $key = "tab.$Index.rect"
    if (-not $s.ContainsKey($key)) { throw "State lacks $key; the tab rail row is unknown." }
    $r = $s[$key] -split ','
    return "$([int]([double]$r[0]+[double]$r[2]/2)),$([int]([double]$r[1]+[double]$r[3]/2))"
}
function New-Tab-Point {
    $s = Read-State
    $r = $s['rail.new_tab'] -split ','
    return "$([int]([double]$r[0]+[double]$r[2]/2)),$([int]([double]$r[1]+[double]$r[3]/2))"
}
function Read-State {
    $lines = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $state = @{}
    foreach ($line in $lines) { $pair = $line -split '=', 2; $state[$pair[0]] = $pair[1].Trim('"') }
    return $state
}
function Assert-Value($Actual, $Expected, [string] $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Close-Point([int] $Index) {
    $s = Read-State
    $r = $s["tab.$Index.close"] -split ','
    return "$([int]([double]$r[0]+[double]$r[2]/2)),$([int]([double]$r[1]+[double]$r[3]/2))"
}
function Click([double] $X, [double] $Y) {
    Invoke-Aio mouse click "$([int]$X),$([int]$Y)" --px
}
function Shot([string] $Label) {
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Frame -Shot (Join-Path $directory "$Label.png")
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}
function Shot-Client([string] $Label) {
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Shot (Join-Path $directory "$Label.png") | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
    return (Join-Path $directory "$Label.png")
}
Invoke-Aio launch --fresh
try {
    Invoke-Aio key Ctrl+Shift+L
    $initial = Read-State
    Assert-Value $initial['rail.row.height'] 32 'rail rows keep the 32 DIP rhythm'
    Assert-Value $initial['rail.docked'] true 'rail docks in a wide window'
    Assert-Value $initial['title.height'] 40 'the title bar keeps its 40 DIP height'
    if ([double]$initial['title.controls_end'] -ge [double]$initial['title.caption_start']) { throw 'the empty title bar is not a caption drag region' }
    Write-Output 'PASS the empty title bar is a caption drag region'
    $session = $initial['session.id']
    Invoke-Aio command tab.new
    Invoke-Aio command tab.select_1
    $state = Read-State
    $close = Close-Point 2
    Invoke-Aio mouse click $close --px
    Assert-Value (Read-State)['tabs.count'] 1 'X closes an inactive tab'
    Assert-Value (Read-State)['session.id'] $session 'closing another tab preserves the active session'
    Invoke-Aio command tab.new
    $state = Read-State
    $close = Close-Point 2
    Invoke-Aio mouse down $close --px
    Invoke-Aio mouse up '10,60' --px
    Assert-Value (Read-State)['tabs.count'] 2 'releasing away cancels close'
    $close = Close-Point 2
    Invoke-Aio mouse click $close --px
    Assert-Value (Read-State)['tabs.count'] 1 'X closes the active tab'
    Invoke-Aio mouse click (New-Tab-Point) --px
    Assert-Value (Read-State)['tabs.count'] 2 'rail footer creates a tab'
    Invoke-Aio key Ctrl+Shift+P
    Assert-Value (Read-State)['palette.open'] true 'palette shortcut works without a title-bar button'
    Invoke-Aio key Esc
    $width = [double]((Read-State)['window.size'] -split 'x')[0]
    Click ($width-69) 20
    Invoke-Aio expect state window.maximized=true
    $width = [double]((Read-State)['window.size'] -split 'x')[0]
    Click ($width-69) 20
    Invoke-Aio expect state window.maximized=false
    Shot dark-title-bar
    $client = Shot-Client title-bar-client
    Add-Type -AssemblyName System.Drawing
    $toggle = (Read-State)['rail.toggle'] -split ',' | ForEach-Object { [int][double]$_ }
    $bitmap = [Drawing.Bitmap]::FromFile($client)
    $bright = 0
    for ($y = $toggle[1]+4; $y -lt $toggle[1]+$toggle[3]-4; $y++) {
        for ($x = $toggle[0]+4; $x -lt $toggle[0]+$toggle[2]-4; $x++) {
            $pixel = $bitmap.GetPixel($x, $y)
            if ($pixel.R -gt 100 -or $pixel.G -gt 100 -or $pixel.B -gt 100) { $bright += 1 }
        }
    }
    $bitmap.Dispose()
    if ($bright -lt 8) { throw "the rail toggle is not painted in its title-bar rect ($bright bright pixels)" }
    Write-Output "PASS rail toggle is painted ($bright bright pixels)"
    Invoke-Aio key 'Ctrl+,'
    Invoke-Aio type input.leader
    Shot leader-settings
    Invoke-Aio dpi 168
    Shot leader-settings-175
    Invoke-Aio dpi 96
    $path = Join-Path $directory 'settings.ini'
    [IO.File]::AppendAllText($path, "`ntheme.mode = light`n")
    Invoke-Aio command settings.reload
    Shot light-title-bar
    Invoke-Aio command tab.close
    Invoke-Aio key 'Ctrl+,'
    Invoke-Aio type 'alt+8'
    Assert-Value (Read-State)['settings.key'] keys.tab.select_8 'shortcut value search finds Select Tab 8'
    Invoke-Aio key Ctrl+A
    Invoke-Aio type al8
    Assert-Value (Read-State)['settings.key'] keys.tab.select_8 'shortcut value search is fuzzy'
    Write-Output 'PASS title bar, click close, settings geometry and binding search'
} finally {
    & $ctl --name $name stop | Out-Null
}
