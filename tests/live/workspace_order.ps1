param([string] $Name = 'work296-order')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $args : $out" }
    return $out
}
function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Aio state)) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}
function Check($Condition, $Label) {
    if (!$Condition) { throw "FAIL $Label" }
    Write-Output "PASS $Label"
}
function Row-Center {
    $row = (Read-State)['workspace.picker.row'] -split ',' | ForEach-Object { [double]$_ }
    return "$([int]($row[0]+40)),$([int]($row[1]+$row[3]/2))"
}
function Select-First {
    $selected = [int](Read-State)['workspace.picker.selected']
    for ($i = 0; $i -lt $selected; $i++) { Invoke-Aio key Up | Out-Null }
}
function Check-Order([string[]] $Names) {
    Invoke-Aio key Esc | Out-Null
    for ($i = 0; $i -lt $Names.Count; $i++) {
        Invoke-Aio command "workspace.select_$($i+1)" | Out-Null
        Check ((Read-State)['workspace.name'] -eq $Names[$i]) "workspace $($i+1) is $($Names[$i])"
    }
}
try {
    Invoke-Aio launch --fresh | Out-Null
    $original = (Read-State)['workspace.name']
    foreach ($workspaceName in @('Alpha', 'Beta')) {
        Invoke-Aio command workspace.new | Out-Null
        Invoke-Aio type $workspaceName | Out-Null
        Invoke-Aio key Enter | Out-Null
    }
    $before = Read-State
    Invoke-Aio command workspace.change | Out-Null
    Select-First
    $start = Row-Center
    Invoke-Aio key Down Down | Out-Null
    $end = Row-Center
    Invoke-Aio mouse drag $start $end --px | Out-Null
    $after = Read-State
    Check ($after['workspace.id'] -eq $before['workspace.id']) 'drag preserves active workspace'
    Check ($after['session.id'] -eq $before['session.id']) 'drag preserves active runtime'
    Check-Order @('Alpha', 'Beta', $original)

    Invoke-Aio command workspace.change | Out-Null
    Select-First
    Invoke-Aio key Right Down Down Down | Out-Null
    Invoke-Aio capture --out "$repo/build/verify/$Name/move-down-menu.png" | Out-Null
    Invoke-Aio key Down Enter | Out-Null
    Check-Order @('Beta', 'Alpha', $original)

    Invoke-Aio command workspace.change | Out-Null
    Select-First
    $start = Row-Center
    Invoke-Aio key Down Down | Out-Null
    $end = Row-Center
    Invoke-Aio mouse down $start --px | Out-Null
    $point = $start -split ',' | ForEach-Object { [int]$_ }
    $floating = "$($point[0]),$($point[1]+40)"
    Invoke-Aio mouse move $floating --px | Out-Null
    $drawn = (Read-State)['workspace.picker.row'] -split ',' | ForEach-Object { [double]$_ }
    Check ([math]::Abs(($drawn[1]+$drawn[3]/2)-($point[1]+40)) -lt 1) 'grabbed row follows pointer'
    Invoke-Aio capture --out "$repo/build/verify/$Name/floating-row.png" | Out-Null
    Invoke-Aio key Esc | Out-Null
    Invoke-Aio mouse up $end --px | Out-Null
    Check-Order @('Beta', 'Alpha', $original)

    Invoke-Aio command workspace.change | Out-Null
    Invoke-Aio type Alpha | Out-Null
    Invoke-Aio key Right Down Down Down Enter | Out-Null
    Check-Order @('Alpha', 'Beta', $original)
    Check ((Read-State)['sessions.count'] -eq '3') 'reordering creates no shells'

    Invoke-Aio stop | Out-Null
    Invoke-Aio launch --keep-layout | Out-Null
    Check-Order @('Alpha', 'Beta', $original)
    Invoke-Aio command workspace.change | Out-Null
    Invoke-Aio capture --out "$repo/build/verify/$Name/reordered.png" | Out-Null
    Write-Output 'PASS workspace reordering journey'
} finally { Invoke-Aio stop | Out-Null }
