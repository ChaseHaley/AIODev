[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'palette-workspace-search'
$directory = Join-Path $repo "build/verify/$name"

function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}

function Read-State {
    $out = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect palette state.' }
    $state = @{}
    foreach ($line in $out) {
        $pair = $line -split '=', 2
        if ($pair.Count -ne 2) { throw "Malformed state entry: $line" }
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}

function Assert-Tabs([string] $Label) {
    Invoke-Aio expect state 'palette.mode=tabs'
    Invoke-Aio expect state 'palette.query=main'
    Invoke-Aio expect state 'palette.items=3'
    $names = @()
    foreach ($index in 0..2) {
        $state = Read-State
        $names += $state['palette.item']
        Invoke-Aio key Down | Out-Null
    }
    if (($names -join ',') -ne ($expectedTitles -join ',')) {
        throw "${Label}: unexpected tab names $($names -join ',')"
    }
    Invoke-Aio state | Set-Content -LiteralPath "$directory/$Label-state.txt"
    if ($Label -eq 'scope-tab') {
        & "$repo/tools/win32.ps1" -Name $name -Shot "$directory/$Label.png" -Frame | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Screenshot failed: $Label" }
    }
    Write-Output "PASS $Label finds all three workspace tabs"
}

Invoke-Aio launch --fresh --size 120x36
try {
    Invoke-Aio wait text 'PS '
    Invoke-Aio command workspace.rename
    Invoke-Aio type 'main'
    Invoke-Aio key Enter
    foreach ($title in @('Shell', 'Logs')) {
        Invoke-Aio command tab.new
        Invoke-Aio wait text 'PS '
        Invoke-Aio command tab.rename
        Invoke-Aio expect state 'rename.open=true'
        Invoke-Aio type $title
        Invoke-Aio expect state "rename.value=$title"
        Invoke-Aio key Enter
    }
    $state = Read-State
    $expectedTitles = @($state['tab.1.title'], $state['tab.2.title'], $state['tab.3.title'])
    if (($expectedTitles -join ',') -match '(?i)main') { throw 'A tab title already matches the workspace query.' }
    # An unrelated workspace's tab must not be returned just because it is open.
    Invoke-Aio command workspace.new
    Invoke-Aio type 'other'
    Invoke-Aio key Enter
    Invoke-Aio wait text 'PS '
    Invoke-Aio command tab.rename
    Invoke-Aio type 'Unrelated'
    Invoke-Aio key Enter
    $other = (Read-State)['workspace.id']

    Invoke-Aio command app.command_palette
    Invoke-Aio type 't:main'
    Assert-Tabs 'prefix'
    Invoke-Aio key Esc

    Invoke-Aio command app.command_palette
    Invoke-Aio key Tab
    Invoke-Aio type 'main'
    Assert-Tabs 'tab-cycle'
    Invoke-Aio key Esc

    Invoke-Aio command app.command_palette
    $state = Read-State
    $rect = @($state['palette.mode.tabs'] -split ',' | ForEach-Object { [double]$_ })
    $x = [int]($rect[0] + $rect[2]/2)
    $y = [int]($rect[1] + $rect[3]/2)
    Invoke-Aio mouse click "$x,$y" --px
    Invoke-Aio type 'main'
    Assert-Tabs 'scope-tab'
    Invoke-Aio key Esc

    # Activate a workspace-matched tab from another workspace and verify its identity.
    Invoke-Aio command app.command_palette
    Invoke-Aio type 't:main'
    Invoke-Aio key Down Enter
    Invoke-Aio expect state 'palette.open=false'
    Invoke-Aio expect state 'tabs.selected=2'
    Invoke-Aio expect state 'tab.2.title=Shell'
    if ((Read-State)['workspace.id'] -eq $other) { throw 'Activation stayed in the other workspace.' }
    Write-Output 'PASS workspace-matched tab activates its owning workspace and tab'
    & "$repo/tools/win32.ps1" -Name $name -Shot "$directory/activated.png" -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
} finally {
    & $ctl --name $name stop | Write-Output
}
