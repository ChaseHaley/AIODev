param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'workspace-dropdown'
$data = Join-Path $repo "build/verify/$name"
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}
function Read-State {
    $out = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $state = @{}
    foreach ($line in $out) { $pair = $line -split '=',2; $state[$pair[0]] = $pair[1].Trim('"') }
    return $state
}
function Rect($State, $Key) { return @($State[$Key] -split ',' | ForEach-Object { [double]$_ }) }
function Native {
    & "$repo/tools/win32.ps1" -Name $name @args
    if ($LASTEXITCODE -ne 0) { throw 'Native workspace input/capture failed.' }
}
function Shot($Label) {
    Invoke-Aio wait frame | Out-Null
    Native -Shot "$data/$Label.png" -Frame | Out-Null
}
function Assert-Fit($Label) {
    $state = Read-State
    $scale = [double]$state['window.scale']
    $r = Rect $state 'workspace.picker.rect'
    $size = $state['window.size'] -split 'x'
    if ($r[0] -ne 5*$scale -or $r[1] -ne 40*$scale -or
        $r[0]+$r[2] -gt [double]$size[0] -or $r[1]+$r[3] -gt [double]$size[1]) {
        throw "Dropdown anchor/fit failed $Label : $($state['workspace.picker.rect']) in $size"
    }
    Write-Output "PASS anchored dropdown fits $Label"
}
Invoke-Aio launch --fresh
try {
    Invoke-Aio wait text 'PS '
    $first = Read-State
    $firstId = $first['workspace.id']
    $firstSession = $first['session.id']
    Invoke-Aio command workspace.new
    Invoke-Aio wait text 'PS '
    $secondId = (Read-State)['workspace.id']
    Invoke-Aio command workspace.rename
    Invoke-Aio type 'Build tools'
    Invoke-Aio key Enter
    Invoke-Aio command workspace.change
    Invoke-Aio expect state workspace.picker.selected=1
    Invoke-Aio key Ctrl+N Ctrl+P
    Invoke-Aio expect state workspace.picker.selected=1
    Invoke-Aio expect state workspace.picker.query=
    Native -Chord '0x11+0x4e' -Activate | Out-Null
    Invoke-Aio expect state workspace.picker.selected=2
    Native -Chord '0x11+0x50' -Activate | Out-Null
    Invoke-Aio expect state workspace.picker.selected=1
    $s = Read-State
    $row = Rect $s 'workspace.picker.row'
    $scale = [double]$s['window.scale']
    Invoke-Aio mouse click "$([int]($row[0]+10)),$([int]($row[1]+$row[3]+4*$scale))" --px
    Invoke-Aio expect state workspace.picker=true
    Invoke-Aio expect state workspace.picker.selected=1
    Shot 'dropdown-divider'
    Invoke-Aio key Esc
    Invoke-Aio command workspace.change_icon
    Invoke-Aio key Right Enter
    Invoke-Aio expect state workspace.icon.preset=1
    Invoke-Aio key Esc
    Invoke-Aio command workspace.change_icon
    Invoke-Aio focus out
    Invoke-Aio expect state workspace.picker=true
    Invoke-Aio focus in
    Native -Text '👩🏽‍💻' | Out-Null
    Invoke-Aio expect state 'workspace.picker.query=👩🏽‍💻'
    Invoke-Aio key Enter
    Invoke-Aio expect state 'workspace.icon.emoji=👩🏽‍💻'
    Shot 'emoji-dropdown'
    Invoke-Aio key Esc
    # Overrides bind existing registry commands without assigning new default chords.
    Add-Content -LiteralPath "$data/settings.ini" -Encoding utf8 -Value @(
        'keys.workspace.select_1 = Ctrl+Alt+1', 'keys.workspace.select_2 = Ctrl+Alt+2')
    Invoke-Aio command settings.reload
    Invoke-Aio key Ctrl+Alt+1
    Invoke-Aio expect state "workspace.id=$firstId"
    Invoke-Aio expect state "session.id=$firstSession"
    Invoke-Aio key Ctrl+Alt+2
    Invoke-Aio expect state "workspace.id=$secondId"
    Invoke-Aio command workspace.select_9
    Invoke-Aio expect state "workspace.id=$secondId"
    foreach ($dpi in @(96,144,168,192)) {
        Invoke-Aio dpi $dpi
        Invoke-Aio resize 46x20
        Invoke-Aio command workspace.change
        Assert-Fit "DPI $dpi narrow"
        Shot "dropdown-$dpi"
        Invoke-Aio key Esc
        Invoke-Aio command workspace.change_icon
        Assert-Fit "icon DPI $dpi narrow"
        Invoke-Aio key Esc Esc
    }
    Invoke-Aio dpi 96
    Invoke-Aio resize 110x32
    Invoke-Aio command workspace.change
    Invoke-Aio key Ctrl+P Shift+Delete
    Invoke-Aio expect state "confirm.workspace=$firstId"
    Invoke-Aio key Esc
    Invoke-Aio command workspace.change
    Invoke-Aio key Ctrl+P
    $hiddenRow = Rect (Read-State) 'workspace.picker.row'
    $deletePoint = "$([int]($hiddenRow[0]+$hiddenRow[2]-18)), $([int]($hiddenRow[1]+17))" -replace ' ',''
    Invoke-Aio mouse move $deletePoint --px
    Invoke-Aio mouse click $deletePoint --px
    Invoke-Aio key End Enter
    Invoke-Aio expect state "confirm.workspace=$firstId"
    Shot 'delete-hidden-confirm'
    Invoke-Aio key Esc
    Invoke-Aio command workspace.change
    $size = (Read-State)['window.size'] -split 'x'
    Invoke-Aio mouse click "$([int]$size[0]-5),$([int]$size[1]-5)" --px
    Invoke-Aio expect state workspace.picker=false
    Invoke-Aio command workspace.change
    Invoke-Aio key Right End Enter
    Invoke-Aio expect state confirm.open=true
    Invoke-Aio expect state "confirm.workspace=$secondId"
    Shot 'delete-current-confirm'
    Invoke-Aio key Esc
    Invoke-Aio expect state "workspace.id=$secondId"
    Invoke-Aio command workspace.delete
    Invoke-Aio expect state confirm.open=true
    Invoke-Aio key Enter
    Invoke-Aio expect state "workspace.id=$firstId"
    Invoke-Aio expect state "session.id=$firstSession"
    Invoke-Aio command workspace.delete
    Shot 'delete-last-confirm'
    Invoke-Aio key Enter
    $last = Read-State
    if ($last['workspace.id'] -eq $firstId -or $last['session.id'] -eq $firstSession) {
        throw 'Last workspace deletion did not create a fresh workspace and session.'
    }
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state workspaces.count=1
    Write-Output 'PASS dropdown divider, CtrlNP/native input, Unicode, index bindings, DPI and confirmed deletion'
} finally {
    Invoke-Aio stop
}
