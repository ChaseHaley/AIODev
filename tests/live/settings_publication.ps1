[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
# A new window opens with its suggested name in its own chip. Accept it, or type a title, and come back.
function Finish-New-Window([string] $Title = '') {
    $state = @{}
    foreach ($line in (& $ctl --name $name state)) { $pair = $line -split '=', 2; $state[$pair[0]] = $pair[1].Trim('"') }
    $newest = (1..[int]$state['windows.count'] | ForEach-Object { [int]$state["window.$_.id"] } | Measure-Object -Maximum).Maximum
    & $ctl --name $name window select $newest | Out-Null
    if ($Title -ne '') { & $ctl --name $name type $Title | Out-Null }
    & $ctl --name $name key Enter | Out-Null
    & $ctl --name $name window select $state['window.id'] | Out-Null
}
$name = 'settings-publication'
$directory = Join-Path $repo "build/verify/$name"
$path = Join-Path $directory 'settings.ini'

function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}
function Read-State {
    $state = @{}
    foreach ($line in (& $ctl --name $name state)) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect state.' }
    return $state
}
function Assert-Value($Actual, $Expected, [string] $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Save-Value([string] $Value) {
    Invoke-Aio key Ctrl+A
    Invoke-Aio type $Value
    Invoke-Aio key Enter
    Assert-Value (Read-State)['settings.error'] false 'the inline write succeeds'
}
function Shot([string] $Label) {
    & $ctl --name $name state | Set-Content (Join-Path $directory "$Label-state.txt")
    # Two windows are open; aioctl capture shoots the selected one on either build.
    Invoke-Aio capture --out (Join-Path $directory "$Label.png")
}

Invoke-Aio launch --fresh
try {
    $first = (Read-State)['window.id']
    Invoke-Aio command settings.open
    Invoke-Aio type font.size
    Invoke-Aio key Tab Ctrl+A
    Invoke-Aio type 19
    Invoke-Aio command window.new
    Finish-New-Window
    $windows = Read-State
    Assert-Value $windows['windows.count'] 2 'the second window is created'
    $second = @($windows.Keys | Where-Object { $_ -match '^window\.\d+\.id$' } |
        ForEach-Object { $windows[$_] } | Where-Object { $_ -ne $first })[0]
    if (-not $second) { throw 'The second window has no ID.' }
    # The app keeps one page, so opening Settings from the second window leaves the draft in the first.
    Invoke-Aio window select $second
    $secondTabs = (Read-State)['tabs.count']
    Invoke-Aio command settings.open
    Assert-Value (Read-State)['tabs.count'] $secondTabs 'the second window gains no settings tab'
    Invoke-Aio window select $first
    Assert-Value (Read-State)['settings.key'] font.size 'the page keeps its selected field'
    Assert-Value (Read-State)['settings.value'] 19 'the page keeps its draft'
    Invoke-Aio command view.tabs_orientation
    Assert-Value (Read-State)['settings.value'] 19 'a disk writer preserves the pending draft'
    Assert-Value (Read-State)['tabs.orientation'] vertical 'the orientation write applies'
    Shot dark-draft
    Invoke-Aio key Enter
    Assert-Value (Read-State)['settings.error'] false 'the preserved draft saves without an internal conflict'
    $saved = [IO.File]::ReadAllText($path)
    foreach ($line in @('font.size = 19', 'tabs.orientation = vertical')) {
        if (-not $saved.Contains($line)) { throw "The combined settings file lacks $line" }
    }
    Write-Output 'PASS the combined file keeps both writers'
    Invoke-Aio key Esc
    Invoke-Aio key Ctrl+A
    Invoke-Aio type theme.name
    Invoke-Aio key Tab Enter Down Enter
    Assert-Value (Read-State)['settings.error'] false 'the page saves again after the first save'
    Assert-Value (Read-State)['theme.name'] studio-light 'the light theme applies to both windows'
    Invoke-Aio key Esc
    Invoke-Aio key Ctrl+A
    Invoke-Aio type font.size
    Invoke-Aio key Tab
    Assert-Value (Read-State)['settings.value'] 19 'the saved field holds its value'
    Shot light-saved
    Invoke-Aio key Ctrl+A
    Invoke-Aio type 21
    [IO.File]::AppendAllText($path, "`n# external owner edit`n")
    $external = [IO.File]::ReadAllText($path)
    Invoke-Aio key Enter
    Assert-Value (Read-State)['settings.error'] true 'a real external edit still conflicts'
    Assert-Value (Read-State)['settings.value'] 21 'a rejected save keeps draft text'
    Assert-Value ([IO.File]::ReadAllText($path)) $external 'a rejected save keeps the external file'
} finally {
    & $ctl --name $name stop | Out-Null
}
