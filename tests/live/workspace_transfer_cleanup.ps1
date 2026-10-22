[CmdletBinding()]
param(
    [string] $Name = ('work130-' + [guid]::NewGuid().ToString('N').Substring(0, 12)),
    [string] $Repository = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [ValidateSet('Dock', 'Tab')] [string] $Mode = 'Dock',
    [ValidateSet('None', 'Settings', 'Terminal', 'Split')] [string] $Remaining = 'None',
    [string] $SourcePosition = '20,80',
    [string] $DestinationPosition = '840,80'
)
$ErrorActionPreference = 'Stop'
$ctl = Join-Path $Repository 'build/aioctl.exe'
$directory = Join-Path $Repository "build/verify/$Name"
function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}
function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Aio state)) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}
function Assert-Equal($Actual, $Expected, [string] $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Host "PASS $Label"
}
function Select-Window([string] $Id) { Invoke-Aio window select $Id | Out-Null }
function Save-State([string] $Label) {
    Invoke-Aio state | Set-Content -LiteralPath "$directory/$Label-state.txt"
}
function Shell-Receipt([string] $Label) {
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio run "Write-Output ('WORK130_${Label}_' + `$PID)" | Out-Null
    Invoke-Aio wait text "WORK130_${Label}_" | Out-Null
    $matches = [regex]::Matches(((Invoke-Aio screen) -join "`n"), "WORK130_${Label}_(\d+)")
    if ($matches.Count -eq 0) { throw "No actual shell PID receipt for $Label" }
    return $matches[$matches.Count-1].Groups[1].Value
}
function Begin-Drag {
    Select-Window $script:source
    $s = Read-State
    $r = @($s["pane.$($s['panes.focused']).rect"] -split ',' | ForEach-Object { [double]$_ })
    $x = [int]($r[0] + [math]::Min(80*[double]$s['window.scale'], $r[2]/3))
    $y = [int]($r[1] + 14*[double]$s['window.scale'])
    Invoke-Aio mouse down "$x,$y" --px | Out-Null
    Invoke-Aio mouse move "$($x+24),$($y+24)" --px | Out-Null
    Invoke-Aio expect state panes.dragging=true | Out-Null
}

try {
    Invoke-Aio launch --fresh | Out-Null
    $initial = Read-State
    Write-Host "RECEIPT app=$($initial['app.pid']) build=$($initial['app.build']) instance=$Name"
    $script:source = $initial['window.id']
    $sourceWorkspace = $initial['workspace.id']
    Invoke-Aio resize 60x20 | Out-Null
    Invoke-Aio window move $SourcePosition | Out-Null
    switch ($Remaining) {
        Settings { Invoke-Aio command settings.open | Out-Null; Invoke-Aio command tab.select_1 | Out-Null }
        Terminal { Invoke-Aio command tab.new | Out-Null; Invoke-Aio command tab.select_1 | Out-Null }
        Split { Invoke-Aio command pane.split_right | Out-Null }
    }
    $movedRuntime = (Read-State)['session.id']
    $movedPid = Shell-Receipt moved
    Invoke-Aio command window.new | Out-Null
    $inventory = Read-State
    $destination = $inventory['window.2.id']
    Select-Window $destination
    Invoke-Aio resize 60x20 | Out-Null
    Invoke-Aio window move $DestinationPosition | Out-Null
    $destinationRuntime = (Read-State)['session.id']
    $destinationPid = Shell-Receipt destination
    $s = Read-State
    $destinationWorkspace = $s['workspace.id']
    $destinationTab = $s['tab.1.id']
    $origin = @($s['window.origin'] -split ',' | ForEach-Object { [double]$_ })
    if ($Mode -eq 'Tab') {
        $targetX = [int]($origin[0] + [double]$s['tabs.x'] + [double]$s['tabs.width'] + 16*[double]$s['window.scale'])
        $targetY = [int]($origin[1] + [double]$s['tabs.height']/2)
    } else {
        $r = @($s["pane.$($s['panes.focused']).rect"] -split ',' | ForEach-Object { [double]$_ })
        $targetX = [int]($origin[0]+$r[0]+$r[2]*0.75)
        $targetY = [int]($origin[1]+$r[1]+$r[3]*0.5)
    }
    $target = "$targetX,$targetY"

    Begin-Drag
    Invoke-Aio mouse move $target --screen | Out-Null
    Invoke-Aio expect state "panes.drop.window=$destination" | Out-Null
    Invoke-Aio expect state panes.drop.shown=true | Out-Null
    Invoke-Aio key Esc | Out-Null
    Invoke-Aio mouse up $target --screen | Out-Null
    Invoke-Aio expect state workspaces.count=2 | Out-Null
    Invoke-Aio expect state windows.count=2 | Out-Null
    Invoke-Aio expect state "workspace.id=$sourceWorkspace" | Out-Null
    Invoke-Aio expect state "session.id=$movedRuntime" | Out-Null
    Assert-Equal (Shell-Receipt moved) $movedPid 'cancel preserves moved shell PID'
    Save-State cancelled

    Begin-Drag
    Invoke-Aio mouse move $target --screen | Out-Null
    Invoke-Aio expect state "panes.drop.window=$destination" | Out-Null
    Invoke-Aio expect state panes.drop.shown=true | Out-Null
    $newTab = ($Mode -eq 'Tab').ToString().ToLowerInvariant()
    Invoke-Aio expect state "panes.drop.new_tab=$newTab" | Out-Null
    Save-State before-commit
    Invoke-Aio mouse up $target --screen | Out-Null
    Select-Window $destination
    Save-State after-commit
    $expected = if ($Remaining -eq 'None') { 1 } else { 2 }
    Invoke-Aio expect state "workspaces.count=$expected"
    Invoke-Aio expect state "windows.count=$expected"
    Invoke-Aio expect state "workspace.id=$destinationWorkspace" | Out-Null
    Invoke-Aio expect state "window.id=$destination" | Out-Null
    Invoke-Aio expect state "tab.1.id=$destinationTab" | Out-Null
    Invoke-Aio expect state "session.id=$movedRuntime" | Out-Null
    Assert-Equal (Shell-Receipt moved) $movedPid 'committed move preserves moved shell PID'
    if ($Mode -eq 'Tab') { Invoke-Aio command tab.select_1 | Out-Null }
    else { Invoke-Aio command pane.focus_left | Out-Null }
    Invoke-Aio expect state "session.id=$destinationRuntime" | Out-Null
    Assert-Equal (Shell-Receipt destination) $destinationPid 'destination shell PID survives'
    if ($Remaining -eq 'None') {
        $rejected = & $ctl --name $Name window select $source 2>&1
        if ($LASTEXITCODE -eq 0) { throw 'Old source window ID unexpectedly accepted.' }
        Write-Host "PASS old source window ID rejected: $rejected"
        Invoke-Aio command workspace.change | Out-Null
        Invoke-Aio type $initial['workspace.name'] | Out-Null
        # No workspace matches: only New Workspace and New Window remain.
        Invoke-Aio expect state workspace.picker.count=2 | Out-Null
        Invoke-Aio key Esc | Out-Null
        Invoke-Aio command workspace.new | Out-Null
        Invoke-Aio expect state workspace.id=3 | Out-Null
        Invoke-Aio expect state 'workspace.name=Workspace 3' | Out-Null
    } else {
        Select-Window $source
        Invoke-Aio expect state "workspace.id=$sourceWorkspace" | Out-Null
        Invoke-Aio expect state panes.count=1 | Out-Null
        if ($Remaining -eq 'Settings') { Invoke-Aio expect state settings.open=true | Out-Null }
    }
    Save-State final
    Write-Host "RECEIPT mode=$Mode remaining=$Remaining moved-runtime=$movedRuntime moved-pid=$movedPid destination-runtime=$destinationRuntime destination-pid=$destinationPid"
} finally {
    & $ctl --name $Name stop
    if ($LASTEXITCODE -ne 0) { throw "Could not stop own instance $Name" }
}
