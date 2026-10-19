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
function Tab-X($State) { if (-not $State.ContainsKey('tabs.x')) { throw 'State lacks tabs.x; the tab strip offset is unknown.' }; return [double]$State['tabs.x'] }
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
function Click([double] $X, [double] $Y) {
    Invoke-Aio mouse click "$([int]$X),$([int]$Y)" --px
}
function Shot([string] $Label) {
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Frame -Shot (Join-Path $directory "$Label.png")
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}
Invoke-Aio launch --fresh
try {
    $initial = Read-State
    Assert-Value $initial['tabs.height'] 40 'tabs share a 40 DIP title bar'
    $session = $initial['session.id']
    Invoke-Aio command tab.new
    Invoke-Aio command tab.select_1
    $state = Read-State
    $tabWidth = [double]$state['tabs.width']
    $tabX = Tab-X $state
    Click ($tabX+$tabWidth*2-17) 20
    Assert-Value (Read-State)['tabs.count'] 1 'X closes an inactive tab'
    Assert-Value (Read-State)['session.id'] $session 'closing another tab preserves the active session'
    Invoke-Aio command tab.new
    $state = Read-State
    $tabWidth = [double]$state['tabs.width']
    $tabX = Tab-X $state
    Invoke-Aio mouse down "$([int]($tabX+$tabWidth*2-17)),20" --px
    Invoke-Aio mouse up '10,60' --px
    Assert-Value (Read-State)['tabs.count'] 2 'releasing away cancels close'
    Click ($tabX+$tabWidth*2-17) 20
    Assert-Value (Read-State)['tabs.count'] 1 'X closes the active tab'
    Click ($tabX+$tabWidth+16) 20
    Assert-Value (Read-State)['tabs.count'] 2 'new-tab button works in the title bar'
    Click ($tabX+$tabWidth*2+48) 20
    Assert-Value (Read-State)['palette.open'] true 'palette button works in the title bar'
    Invoke-Aio key Esc
    $width = [double]((Read-State)['window.size'] -split 'x')[0]
    Click ($width-69) 20
    Invoke-Aio expect state window.maximized=true
    $width = [double]((Read-State)['window.size'] -split 'x')[0]
    Click ($width-69) 20
    Invoke-Aio expect state window.maximized=false
    Shot dark-title-bar
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
