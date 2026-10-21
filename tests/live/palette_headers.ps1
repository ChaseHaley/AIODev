[CmdletBinding()]
param(
    [string] $Repository = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [ValidatePattern('^[A-Za-z0-9_-]{1,32}$')] [string] $Name = 'palette-headers-design07',
    [switch] $Prepared,
    [switch] $Capture
)

$ErrorActionPreference = 'Stop'
$ctl = Join-Path $Repository 'build/aioctl.exe'
$directory = Join-Path $Repository "build/verify/$Name"

function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}

function Shot([string] $Label) {
    if (-not $Capture) { return }
    Start-Sleep -Milliseconds 250
    Invoke-Aio state | Set-Content -LiteralPath "$directory/$Label-state.txt"
    & (Join-Path $Repository 'tools/win32.ps1') -Name $Name -Shot "$directory/$Label.png" -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Screenshot failed: $Label" }
}

function Search([string] $Query) {
    Invoke-Aio command app.command_palette
    Invoke-Aio type $Query
    Invoke-Aio expect state "palette.query=$Query"
}

function Read-State {
    $out = & $ctl --name $Name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect palette state.' }
    $state = @{}
    foreach ($line in $out) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}

if (-not $Prepared) { Invoke-Aio launch --fresh }
try {
    Invoke-Aio command settings.open
    Invoke-Aio type font
    Invoke-Aio expect state settings.filter=font
    Search 'terminal setting'
    Shot 'terminal-setting'
    Invoke-Aio expect state palette.items=3
    Invoke-Aio expect state palette.item=terminal.copy_on_select
    Invoke-Aio key Ctrl+N
    Invoke-Aio expect state palette.selected=1
    Invoke-Aio expect state palette.item=terminal.confirm_multiline_paste
    Invoke-Aio key Ctrl+N
    Invoke-Aio expect state palette.item=terminal.minimum_contrast
    Invoke-Aio key Ctrl+P
    Invoke-Aio expect state palette.item=terminal.confirm_multiline_paste
    Invoke-Aio key Enter
    Invoke-Aio expect state palette.open=false
    Invoke-Aio expect state 'settings.filter='
    Invoke-Aio expect state settings.key=terminal.confirm_multiline_paste
    Invoke-Aio expect state settings.editing=true
    Shot 'target-setting-focused'

    Search 'terminal settings'
    Invoke-Aio expect state palette.items=3
    Invoke-Aio expect state palette.item=terminal.copy_on_select
    Invoke-Aio key Ctrl+A
    Invoke-Aio type 'terminal settings contrast'
    Invoke-Aio expect state 'palette.query=terminal settings contrast'
    Invoke-Aio expect state palette.selected=0
    Invoke-Aio expect state palette.items=1
    Invoke-Aio expect state palette.item=terminal.minimum_contrast
    Shot 'header-and-title-highlights'
    Invoke-Aio key Enter
    Invoke-Aio expect state settings.key=terminal.minimum_contrast
    Invoke-Aio expect state settings.editing=true

    Search 'terminal setting copy'
    Invoke-Aio expect state palette.items=1
    Invoke-Aio expect state palette.item=terminal.copy_on_select
    Invoke-Aio key Enter
    Invoke-Aio expect state settings.key=terminal.copy_on_select
    Invoke-Aio expect state settings.editing=true

    foreach ($query in @('setting', 'settings', 'settin')) {
        Search $query
        Invoke-Aio expect state palette.item=settings.open
        Shot "title-priority-$query"
    }
    Search 'term'
    $found = @{}
    $state = Read-State
    $count = [int]$state['palette.items']
    for ($index = 0; $index -lt $count; $index++) {
        $found[$state['palette.item']] = $true
        Invoke-Aio key Ctrl+N
        $state = Read-State
    }
    foreach ($item in @('terminal.restart_shell', 'terminal.copy_on_select', 'terminal.minimum_contrast')) {
        if (-not $found.ContainsKey($item)) { throw "term failed to find $item" }
        Write-Output "PASS term fuzzy-matches $item"
    }
    Search 'panes'
    Invoke-Aio key Ctrl+N Ctrl+P
    Invoke-Aio expect state palette.selected=0
    Invoke-Aio key Ctrl+A Backspace
    Invoke-Aio expect state 'palette.query='
    Invoke-Aio type 'terminal settings zzz'
    Invoke-Aio expect state palette.items=0
    Invoke-Aio key Esc
    Invoke-Aio expect state palette.open=false
} finally {
    if (-not $Prepared) { & $ctl --name $Name stop | Write-Output }
}
