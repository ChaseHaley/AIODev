[CmdletBinding()]
param(
    [string] $Repository = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [ValidatePattern('^[A-Za-z0-9_-]{1,32}$')] [string] $Name = 'palette-modes-work122',
    [switch] $Prepared,
    [switch] $Capture
)

$ErrorActionPreference = 'Stop'
$ctl = Join-Path $Repository 'build/aioctl.exe'
$directory = Join-Path $Repository "build/verify/$Name"
New-Item -ItemType Directory -Force $directory | Out-Null

function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}

function Read-State {
    $out = & $ctl --name $Name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect palette state.' }
    $state = @{}
    foreach ($line in $out) {
        $pair = $line -split '=', 2
        if ($pair.Count -ne 2) { throw "Malformed state entry: $line" }
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}

function Assert-Match([string] $Actual, [string] $Pattern, [string] $Label) {
    if ($Actual -notmatch $Pattern) { throw "${Label}: $Actual did not match $Pattern" }
    Write-Output "PASS $Label ($Actual)"
}

function Shot([string] $Label) {
    Invoke-Aio state | Set-Content -LiteralPath "$directory/$Label-state.txt"
    if (-not $Capture) { return }
    Start-Sleep -Milliseconds 250
    & (Join-Path $Repository 'tools/win32.ps1') -Name $Name -Shot "$directory/$Label.png" -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Screenshot failed: $Label" }
}

if (-not $Prepared) { Invoke-Aio launch --fresh --size 120x36 }
try {
    # Give the one tab a name that proves the tab domain instead of relying on a shell title.
    Invoke-Aio command tab.rename
    Invoke-Aio type 'AIODev'
    Invoke-Aio key Enter
    Invoke-Aio command app.command_palette
    Shot 'all-empty'
    Invoke-Aio type 'ai'
    Invoke-Aio expect state 'palette.mode=all'
    $state = Read-State
    if ([int]$state['palette.items'] -lt 2) { throw 'all-mode ai found too little.' }
    Shot 'all-sections'
    Invoke-Aio key Ctrl+A Backspace
    Invoke-Aio type 't:aio'
    Invoke-Aio expect state 'palette.mode=tabs'
    Invoke-Aio expect state 'palette.chip=t:'
    Invoke-Aio expect state 'palette.query=aio'
    $state = Read-State
    Assert-Match $state['palette.item'] '(?i)aio' 't:aio tab result'
    Shot 'tabs-chip'

    Invoke-Aio key Tab
    Invoke-Aio expect state 'palette.mode=workspaces'
    Invoke-Aio expect state 'palette.chip=w:'
    Invoke-Aio key Tab
    Invoke-Aio expect state 'palette.mode=settings'
    Invoke-Aio key Tab
    Invoke-Aio expect state 'palette.mode=commands'
    Invoke-Aio key Tab
    Invoke-Aio expect state 'palette.mode=all'
    Invoke-Aio expect state 'palette.chip='
    Write-Output 'PASS Tab cycles chips and returns to all'

    Invoke-Aio key Tab
    Invoke-Aio expect state 'palette.mode=tabs'
    $state = Read-State
    $panel = @($state['palette.panel'] -split ',' | ForEach-Object { [double]$_ })
    $scale = [double]$state['window.scale']
    $chipX = [int]($panel[0] + 14*$scale + 20*$scale)
    $chipY = [int]($panel[1] + 28*$scale + 12*$scale)
    Invoke-Aio mouse click "$chipX,$chipY" --px
    Shot 'chip-menu-open'
    $menuX = [int]($panel[0] + 14*$scale + 40*$scale)
    $menuY = [int]($panel[1] + 68*$scale + 4*$scale + 2*26*$scale + 13*$scale)
    Invoke-Aio mouse click "$menuX,$menuY" --px
    Invoke-Aio expect state 'palette.mode=workspaces'
    Assert-Match (Read-State)['palette.chip'] 'w:' 'chip menu selected workspaces'
    Shot 'chip-menu-workspaces'

    Invoke-Aio key Tab
    Invoke-Aio expect state 'palette.mode=settings'
    Invoke-Aio key Ctrl+A
    Invoke-Aio type 'w:Workspace'
    Invoke-Aio expect state 'palette.mode=workspaces'
    Invoke-Aio expect state 'palette.query=Workspace'
    $state = Read-State
    Assert-Match $state['palette.item'] 'Workspace' 'w: workspace result'
    Shot 'workspace-search'

    Invoke-Aio key Ctrl+A
    Invoke-Aio type 's:theme'
    Invoke-Aio expect state 'palette.mode=settings'
    Invoke-Aio expect state 'palette.query=theme'
    $state = Read-State
    Assert-Match $state['palette.item'] '^theme\.' 's: setting result'
    Invoke-Aio key Enter
    Invoke-Aio expect state 'palette.open=false'
    Assert-Match (Read-State)['settings.key'] '^theme\.' 'setting revealed in Settings'
    Shot 'setting-revealed'
} finally {
    if (-not $Prepared) { & $ctl --name $Name stop | Write-Output }
}
