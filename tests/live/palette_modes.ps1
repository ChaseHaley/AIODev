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

function Assert-Layout {
    $state = Read-State
    $size = @($state['window.size'] -split 'x' | ForEach-Object { [double]$_ })
    $panel = @($state['palette.panel'] -split ',' | ForEach-Object { [double]$_ })
    $input = @($state['palette.input'] -split ',' | ForEach-Object { [double]$_ })
    if ($panel[0] -lt 0 -or $panel[1] -lt 0 -or $panel[0]+$panel[2] -gt $size[0]+0.01 -or
        $panel[1]+$panel[3] -gt $size[1]+0.01) { throw 'Palette extends outside the client.' }
    foreach ($mode in @('all', 'tabs', 'workspaces', 'settings', 'commands')) {
        $rect = @($state["palette.mode.$mode"] -split ',' | ForEach-Object { [double]$_ })
        if ($rect[2] -le 0 -or $rect[3] -le 0 -or $rect[0] -lt $panel[0] -or
            $rect[0]+$rect[2] -gt $panel[0]+$panel[2]+0.01 -or
            $rect[1]+$rect[3] -gt $input[1]+0.01) { throw "Invalid scope bounds: $mode" }
    }
    if ([int]$state['palette.rows'] -lt 1) { throw 'No complete result row remains.' }
    Write-Output "PASS scope tabs and query fit $($state['window.size']) at $($state['window.dpi']) DPI"
}

if (-not $Prepared) { Invoke-Aio launch --fresh --size 120x36 }
try {
    Invoke-Aio command workspace.rename
    Invoke-Aio key Ctrl+A
    Invoke-Aio type 'Workspace palette test'
    Invoke-Aio key Enter
    Invoke-Aio key Esc
    Invoke-Aio expect state 'workspace.name=Workspace palette test'
    # Give the one tab a name that proves the tab domain instead of relying on a shell title.
    Invoke-Aio command tab.rename
    Invoke-Aio type 'AIODev'
    Invoke-Aio key Enter
    Invoke-Aio command app.command_palette
    Invoke-Aio doctor
    Assert-Layout
    Shot 'all-empty'
    Invoke-Aio type 'ai'
    Invoke-Aio expect state 'palette.mode=all'
    $state = Read-State
    if ([int]$state['palette.items'] -lt 2) { throw 'all-mode ai found too little.' }
    Shot 'all-sections'
    Invoke-Aio key Ctrl+A Backspace
    Invoke-Aio type 't:aio'
    Invoke-Aio expect state 'palette.mode=tabs'
    Invoke-Aio expect state 'palette.prefix=t:'
    Invoke-Aio expect state 'palette.query=aio'
    $state = Read-State
    Assert-Match $state['palette.item'] '(?i)aio' 't:aio tab result'
    Shot 'tabs-scope'

    Invoke-Aio key Tab
    Invoke-Aio expect state 'palette.mode=workspaces'
    Invoke-Aio expect state 'palette.prefix=w:'
    Invoke-Aio key Tab
    Invoke-Aio expect state 'palette.mode=settings'
    Invoke-Aio key Tab
    Invoke-Aio expect state 'palette.mode=commands'
    Invoke-Aio key Tab
    Invoke-Aio expect state 'palette.mode=all'
    Invoke-Aio expect state 'palette.prefix='
    Write-Output 'PASS Tab cycles scopes and returns to all'

    foreach ($mode in @('commands', 'settings', 'workspaces', 'tabs', 'all')) {
        Invoke-Aio key Shift+Tab
        Invoke-Aio expect state "palette.mode=$mode"
        Invoke-Aio expect state 'palette.query=aio'
    }
    Write-Output 'PASS Shift+Tab cycles modes backwards, wraps and preserves the query'

    Invoke-Aio key Tab
    Invoke-Aio expect state 'palette.mode=tabs'
    $state = Read-State
    foreach ($mode in @('commands', 'settings', 'all', 'tabs', 'workspaces')) {
        $state = Read-State
        $rect = @($state["palette.mode.$mode"] -split ',' | ForEach-Object { [double]$_ })
        $x = [int]($rect[0] + $rect[2]/2)
        $y = [int]($rect[1] + $rect[3]/2)
        Invoke-Aio mouse click "$x,$y" --px
        Invoke-Aio expect state "palette.mode=$mode"
        Invoke-Aio expect state 'palette.query=aio'
    }
    Invoke-Aio expect state 'palette.mode=workspaces'
    Assert-Match (Read-State)['palette.prefix'] 'w:' 'scope tab selected workspaces'
    Shot 'scope-tabs-workspaces'

    Invoke-Aio key Ctrl+A Left Backspace
    Invoke-Aio expect state 'palette.mode=all'
    Invoke-Aio expect state 'palette.query=aio'
    Write-Output 'PASS Backspace at query start returns to All without changing the query'

    Invoke-Aio command app.palette_settings
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

    Invoke-Aio command tab.select_1
    Invoke-Aio command app.command_palette
    Invoke-Aio type 't:aio'
    Invoke-Aio dpi 144
    Invoke-Aio resize 46x18
    Assert-Layout
    Shot 'scope-tabs-narrow-dark'

    $path = Join-Path $directory 'settings.ini'
    $settingsText = [IO.File]::ReadAllText($path)
    $settingsText = [regex]::Replace($settingsText, '(?m)^theme\.name\s*=.*\r?\n?', '')
    [IO.File]::WriteAllText($path, $settingsText.TrimEnd()+"`ntheme.name = studio-light`n")
    Invoke-Aio command settings.reload
    Invoke-Aio expect state 'theme.name=studio-light'
    Invoke-Aio command app.command_palette
    Invoke-Aio type 't:aio'
    Assert-Layout
    Shot 'scope-tabs-narrow-light'

    $state = Read-State
    $input = @($state['palette.input'] -split ',' | ForEach-Object { [double]$_ })
    $scale = [double]$state['window.scale']
    $start = "$([int]($input[0]+44*$scale)),$([int]($input[1]+32*$scale))"
    $end = "$([int]($input[0]+$input[2]-16*$scale)),$([int]($input[1]+32*$scale))"
    Invoke-Aio mouse drag $start $end --px
    Invoke-Aio type 'c:Reload Settings'
    Invoke-Aio expect state 'palette.mode=commands'
    Invoke-Aio expect state 'palette.query=Reload Settings'
    Invoke-Aio expect state 'palette.item=settings.reload'
    Shot 'scope-tabs-command-light'
    Invoke-Aio key Enter
    Invoke-Aio expect state 'palette.open=false'
    Invoke-Aio doctor
} finally {
    if (-not $Prepared) { & $ctl --name $Name stop | Write-Output }
}
