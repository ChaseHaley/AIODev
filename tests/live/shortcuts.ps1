[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'shortcut-policy'
$data = Join-Path $repo "build/verify/$name"
$path = Join-Path $data 'settings.ini'

function Invoke-Aio {
    Write-Output ("> aioctl --name $name " + ($args -join ' '))
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl failed: $out" }
    $out | Write-Output
}

function Read-State {
    $out = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $state = @{}
    foreach ($line in $out) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1]
    }
    return $state
}

function Assert-Value($Actual, $Expected, [string] $Label) {
    if ($Actual -ne $Expected) { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}

function Configure([string] $Bindings) {
    [IO.File]::WriteAllText($path, $script:base + "`n" + $Bindings + "`n")
    Invoke-Aio command settings.reload
}

function Assert-Conflict([string] $Winner) {
    $notice = (Read-State)['notice.settings']
    foreach ($part in @('input.leader', 'tab.new', 'settings.ini:', "$Winner wins")) {
        if ($notice -notlike "*$part*") { throw "Missing $part in $notice" }
    }
    Write-Output "PASS named conflict and source locations: $notice"
}

function Close-Settings {
    if ((Read-State)['settings.open'] -eq 'true') {
        Invoke-Aio command settings.open
        Invoke-Aio command tab.close
    }
}

function Open-Shortcut {
    Invoke-Aio key Ctrl+Shift+P
    Invoke-Aio type 'Change Shortcut'
    Invoke-Aio expect state palette.item=settings.change_shortcut
    Invoke-Aio key Enter
    Invoke-Aio expect state settings.open=true
    Invoke-Aio expect state settings.filter=keys.
    Invoke-Aio key Ctrl+A
    Invoke-Aio type keys.tab.new
    Invoke-Aio expect state settings.key=keys.tab.new
}

function Assert-LeaderDelivery([string] $Leader, [string] $Chord, [int] $Code) {
    Configure ("input.leader = $Leader`nkeys.tab.new = Ctrl+Shift+T, Leader+T")
    Invoke-Aio expect state leader.enabled=true
    Invoke-Aio run 'Clear-Host'
    Invoke-Aio type 'Write-Output ("LEADER_"+"READY"); $k=[Console]::ReadKey($true); Write-Output ("CODE_"+[int]$k.KeyChar); $k=[Console]::ReadKey($true); Write-Output ("SECOND_"+[int]$k.KeyChar)'
    Invoke-Aio key Enter
    Invoke-Aio wait text LEADER_READY
    Invoke-Aio command edit.select_all
    if ((Read-State)['session.selection'] -eq 'none') { throw 'Selection fixture failed.' }
    Invoke-Aio key $Chord
    Invoke-Aio expect state leader.pending=true
    Invoke-Aio expect no-text "CODE_$Code"
    Invoke-Aio key $Chord
    Invoke-Aio expect state leader.pending=false
    Invoke-Aio expect state session.selection=none
    if ((Read-State).ContainsKey('notice.leader')) { throw 'Leader notice remains after forwarding.' }
    Invoke-Aio wait text "CODE_$Code"
    Invoke-Aio key X
    Invoke-Aio wait text SECOND_120
    Invoke-Aio expect no-text "SECOND_$Code"
    Invoke-Aio wait idle
    Write-Output "PASS doubled $Leader sends exactly one terminal key press"
}

Invoke-Aio launch --fresh
try {
    $script:base = [regex]::Replace([IO.File]::ReadAllText($path), '(?m)^input\.leader\s*=.*\r?\n?', '')
    Invoke-Aio expect state leader.enabled=false
    Configure "keys.tab.new = Ctrl+B, Ctrl+Shift+T`ninput.leader = Ctrl+B`nkeys.tab.close = Leader+W"
    Invoke-Aio expect state leader.enabled=true
    Assert-Conflict input.leader
    Invoke-Aio key Ctrl+Shift+T
    Invoke-Aio expect state tabs.count=2
    foreach ($physicalLeader in @($false, $true)) {
        $prefix = if ($physicalLeader) { 'Physical+Ctrl+B' } else { 'Ctrl+B' }
        $direct = if ($physicalLeader) { 'Ctrl+B' } else { 'Physical+Ctrl+B' }
        Configure "input.leader = $prefix`nkeys.tab.new = $direct, Ctrl+Shift+T"
        Invoke-Aio expect state leader.enabled=false
        Assert-Conflict tab.new
        $tabs = [int](Read-State)['tabs.count']
        Invoke-Aio key Ctrl+B
        Invoke-Aio expect state "tabs.count=$($tabs+1)"
        Invoke-Aio command tab.close
        Configure "keys.tab.new = $direct, Ctrl+Shift+T`ninput.leader = $prefix"
        Invoke-Aio expect state leader.enabled=true
        Assert-Conflict input.leader
        Invoke-Aio key Ctrl+B
        Invoke-Aio expect state leader.pending=true
        Invoke-Aio expect state "tabs.count=$tabs"
        Invoke-Aio key Esc
        Invoke-Aio key Ctrl+Shift+T
        Invoke-Aio expect state "tabs.count=$($tabs+1)"
        Invoke-Aio command tab.close
    }
    # A rejected override has no effective file origin: tab.new falls back to
    # Ctrl+Shift+T even though the rejected attempted override is written later.
    Configure "input.leader = Ctrl+Shift+T`nkeys.tab.new = Ctrl+Shift+P"
    Invoke-Aio expect state leader.enabled=true
    $notice = (Read-State)['notice.settings']
    foreach ($part in @('tab.new', 'defaults', 'input.leader wins', 'already used by', 'app.command_palette')) {
        if ($notice -notlike "*$part*") { throw "Missing effective-origin diagnostic $part in $notice" }
    }
    Write-Output 'PASS rejected override retains default origin for prefix ordering'
    Configure "keys.tab.new = Ctrl+B, Ctrl+Shift+T`ninput.leader = Ctrl+B`nkeys.tab.close = Leader+W"
    Invoke-Aio key Ctrl+B
    Invoke-Aio expect state leader.pending=true
    Invoke-Aio expect state tabs.count=2
    Invoke-Aio key W
    Invoke-Aio expect state tabs.count=1
    Configure "input.leader = Ctrl+B`nkeys.tab.new = Ctrl+B, Ctrl+Shift+T"
    Invoke-Aio expect state leader.enabled=false
    Assert-Conflict tab.new
    Invoke-Aio key Ctrl+B
    Invoke-Aio expect state leader.pending=false
    Invoke-Aio expect state tabs.count=2
    Open-Shortcut
    $beforeCancel = [IO.File]::ReadAllText($path)
    Invoke-Aio key Tab
    Invoke-Aio expect state settings.popup=Shortcuts
    Invoke-Aio key Enter Ctrl+Alt+Y
    Assert-Value (Read-State)['settings.value'].Trim('"') 'Ctrl+Alt+Y, Ctrl+Shift+T' 'capture replaces only the chosen alternative'
    Invoke-Aio key Esc
    Invoke-Aio expect state settings.capturing=false
    Invoke-Aio expect state settings.open=true
    Close-Settings
    Assert-Value ([IO.File]::ReadAllText($path)) $beforeCancel 'cancel leaves shortcut file unchanged'
    Open-Shortcut
    Invoke-Aio key Shift+Tab Space Tab Tab
    Invoke-Aio expect state settings.popup=Shortcuts
    Invoke-Aio key Enter
    Invoke-Aio expect state settings.capturing=true
    Invoke-Aio key Ctrl+Y Enter
    Invoke-Aio expect state settings.error=false
    if ([IO.File]::ReadAllText($path) -notlike '*keys.tab.new = Physical+Ctrl+Y, Ctrl+Shift+T*') { throw 'UI did not persist shortcut.' }
    Write-Output 'PASS shortcut UI and file share the physical binding model'
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Shot (Join-Path $data 'shortcut-editor.png')
    Close-Settings
    Invoke-Aio key Ctrl+Y
    Invoke-Aio expect state tabs.count=3
    Invoke-Aio key Ctrl+Shift+T
    Invoke-Aio expect state tabs.count=4
    Write-Output 'PASS untouched alternative remains bound'
    Invoke-Aio key Ctrl+Shift+W
    Invoke-Aio expect state tabs.count=3
    Open-Shortcut
    Invoke-Aio key Ctrl+R
    Invoke-Aio expect state settings.error=false
    Close-Settings
    Invoke-Aio key Ctrl+Shift+T
    Invoke-Aio expect state tabs.count=4
    Configure 'input.leader = Ctrl+Shift+T'
    Invoke-Aio expect state leader.enabled=true
    Assert-Conflict input.leader
    if ((Read-State)['notice.settings'] -notlike '*defaults*') { throw 'Default origin missing.' }
    Invoke-Aio key Ctrl+Shift+T
    Invoke-Aio expect state tabs.count=4
    Invoke-Aio expect state leader.pending=true
    Invoke-Aio key Esc
    Invoke-Aio expect state leader.pending=false
    Configure "input.leader = Ctrl+B`nkeys.tab.new = Ctrl+B, Ctrl+Shift+T"
    Invoke-Aio command settings.open
    Invoke-Aio type input.leader
    Invoke-Aio key Tab
    if ((Read-State)['settings.popup'] -eq 'Shortcuts') { Invoke-Aio key Enter }
    Invoke-Aio key Ctrl+Shift+P Enter
    Invoke-Aio expect state settings.error=false
    if ((Read-State)['settings.message'] -notlike '*app.command_palette*') { throw 'UI warning does not name both bindings.' }
    Write-Output 'PASS UI saves source-order conflict as a named nonfatal warning'
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Shot (Join-Path $data 'shortcut-warning.png')
    Close-Settings
    Assert-LeaderDelivery Ctrl+B Ctrl+B 2
    Assert-LeaderDelivery Physical+Ctrl+B Ctrl+B 2
    Assert-LeaderDelivery Esc Esc 27
    Invoke-Aio command terminal.find
    Invoke-Aio key Esc
    Invoke-Aio expect state find.open=false
    Invoke-Aio expect state leader.pending=false
    Configure "input.leader = Ctrl+B`nkeys.tab.new = Ctrl+Shift+T, Leader+T"
    Invoke-Aio key Ctrl+B
    Invoke-Aio key T
    Invoke-Aio expect state tabs.count=5
    Invoke-Aio key Ctrl+B Esc
    Invoke-Aio expect state leader.pending=false
    Invoke-Aio key Ctrl+B
    Invoke-Aio command app.command_palette
    Invoke-Aio expect state leader.pending=false
    if ((Read-State).ContainsKey('notice.leader')) { throw 'Palette retained a stale leader notice.' }
    Invoke-Aio key Esc
    Invoke-Aio key Ctrl+B
    Invoke-Aio command terminal.find
    Invoke-Aio expect state leader.pending=false
    Invoke-Aio key Ctrl+B
    Invoke-Aio expect state leader.pending=true
    Invoke-Aio key Ctrl+B
    Invoke-Aio expect state leader.pending=false
    Invoke-Aio expect state find.open=true
    Invoke-Aio key Esc
    Invoke-Aio expect state find.open=false
    Invoke-Aio key Ctrl+B
    Invoke-Aio focus out
    Invoke-Aio expect state leader.pending=false
    Invoke-Aio focus in
    Invoke-Aio key Ctrl+B
    Invoke-Aio command settings.reload
    Invoke-Aio expect state leader.pending=false
    Invoke-Aio key Ctrl+B
    Start-Sleep -Milliseconds 2200
    Invoke-Aio expect state leader.pending=false
    $persisted = Join-Path $data 'persisted.ini'
    Copy-Item -LiteralPath $path -Destination $persisted -Force
    Invoke-Aio stop
    Invoke-Aio launch --settings $persisted
    Invoke-Aio expect state leader.enabled=true
    Invoke-Aio key Ctrl+B T
    Invoke-Aio expect state tabs.count=2
    Write-Output 'PASS shortcut policy persists across restart'
    Write-Output 'PASS shortcut policy journey'
} finally {
    Invoke-Aio stop
}
