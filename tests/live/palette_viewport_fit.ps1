[CmdletBinding()]
param(
    [string] $Repository = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [ValidatePattern('^[A-Za-z0-9_-]{1,32}$')] [string] $Name = 'palette-fit-6fa273c0',
    [ValidateRange(48, 768)] [int] $Dpi = 192,
    [string] $Size = '46x20',
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

function Assert-Equal($Actual, $Expected, [string] $Label) {
    if ($Actual -ne $Expected) { throw "${Label}: expected $Expected, observed $Actual" }
    Write-Output "PASS $Label ($Actual)"
}

function Shot([string] $Label) {
    Invoke-Aio state | Set-Content -LiteralPath "$directory/$Label-state.txt"
    if (-not $Capture) { return }
    Start-Sleep -Milliseconds 250
    & (Join-Path $Repository 'tools/win32.ps1') -Name $Name -Shot "$directory/$Label.png" -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Screenshot failed: $Label" }
}

function Assert-Fit([string] $Label) {
    $s = Read-State
    foreach ($field in @('palette.panel', 'palette.list', 'palette.rows', 'palette.scroll', 'palette.row_height')) {
        if (-not $s.ContainsKey($field)) { throw "Missing $field; baseline needs verify-only commit 865cf60." }
    }
    $sizeParts = $s['window.size'] -split 'x'
    $width, $height = [double]$sizeParts[0], [double]$sizeParts[1]
    foreach ($field in @('palette.panel', 'palette.list')) {
        $rect = @($s[$field] -split ',' | ForEach-Object { [double]$_ })
        if ($rect.Count -ne 4 -or $rect[0] -lt 0 -or $rect[1] -lt 0 -or
            $rect[2] -lt 0 -or $rect[3] -lt 0 -or $rect[0]+$rect[2] -gt $width+0.01 -or
            $rect[1]+$rect[3] -gt $height+0.01) {
            throw "$Label $field=$($s[$field]) exceeds actual client $($s['window.size'])"
        }
    }
    $panel = @($s['palette.panel'] -split ',' | ForEach-Object { [double]$_ })
    if ($panel[1]+$panel[3]+[double]$s['window.scale'] -gt $height+0.01) {
        throw "$Label panel border extends below actual client: $($s['palette.panel'])"
    }
    $rows, $scroll, $selected = [int]$s['palette.rows'], [int]$s['palette.scroll'], [int]$s['palette.selected']
    $items = [int]$s['palette.items']
    if ($rows -lt 1 -or $rows -gt 8 -or $scroll -lt 0 -or $scroll -gt [Math]::Max(0, $items-$rows)) {
        throw "$Label invalid row/scroll bounds: rows=$rows scroll=$scroll items=$items"
    }
    if ($items -gt 0 -and ($selected -lt $scroll -or $selected -ge $scroll+$rows)) {
        throw "$Label selected=$selected outside visible rows $scroll..$($scroll+$rows-1)"
    }
    $list = @($s['palette.list'] -split ',' | ForEach-Object { [double]$_ })
    if ($items -gt 0 -and $list[1]+($selected-$scroll+1)*[double]$s['palette.row_height'] -gt $height+0.01) {
        throw "$Label selected result extends below client height $height"
    }
    Write-Output "PASS $Label production layout fits $($s['window.size']) rows=$rows selected=$selected scroll=$scroll"
}

function Search([string] $Query) {
    Invoke-Aio command app.command_palette
    Invoke-Aio type $Query
    Invoke-Aio expect state "palette.query=$Query"
}

if (-not $Prepared) { Invoke-Aio launch --fresh }
try {
    Invoke-Aio dpi $Dpi
    Invoke-Aio resize $Size
    foreach ($query in @('setting', 'settings', 'settin')) {
        Search $query
        Invoke-Aio expect state palette.item=settings.open
        $count = [int](Read-State)['palette.items']
        Assert-Equal $count 59 "$query retains all existing results"
        Shot "title-priority-$query"
        Assert-Fit "$query first row"
        Invoke-Aio key End
        Assert-Equal ([int](Read-State)['palette.selected']) ($count-1) "$query End reaches final result"
        Assert-Fit "$query End"
        Shot "end-$query"
        Invoke-Aio key Up Down
        Assert-Equal ([int](Read-State)['palette.selected']) ($count-1) "$query arrows retain final visibility"
        Assert-Fit "$query arrows at final result"
        Invoke-Aio key Home PageDown
        Assert-Equal (Read-State)['palette.selected'] (Read-State)['palette.rows'] "$query PageDown uses visible capacity"
        Assert-Fit "$query PageDown"
        Invoke-Aio key PageUp
        Invoke-Aio expect state palette.selected=0
        for ($index = 0; $index -lt $count; $index++) {
            Invoke-Aio key Ctrl+N | Out-Null
            Assert-Fit "$query Ctrl+N $index"
        }
        for ($index = 0; $index -lt $count; $index++) {
            Invoke-Aio key Ctrl+P | Out-Null
            Assert-Fit "$query Ctrl+P $index"
        }
        Invoke-Aio key Down Up
        Invoke-Aio expect state palette.selected=0
        $s = Read-State
        $list = @($s['palette.list'] -split ',' | ForEach-Object { [double]$_ })
        $x, $y = [int]($list[0]+$list[2]/2), [int]($list[1]+$list[3]-[double]$s['palette.row_height']/2)
        for ($index = 0; $index -lt $count; $index++) {
            Invoke-Aio mouse wheel "$x,$y" -1 --px | Out-Null
            Assert-Fit "$query wheel $index"
        }
        Invoke-Aio mouse move "$x,$y" --px
        Assert-Equal ([int](Read-State)['palette.selected']) ($count-1) "$query hover final complete row"
        $target = (Read-State)['palette.item']
        Invoke-Aio mouse click "$x,$y" --px
        Invoke-Aio expect state palette.open=false
        Invoke-Aio expect state "settings.key=$target"
        Invoke-Aio expect state settings.editing=true
    }
    Search 'setting'
    Invoke-Aio key End Ctrl+A
    Invoke-Aio resize 46x12
    Assert-Fit 'resize retains final selection'
    Invoke-Aio dpi 144
    Assert-Fit 'DPI change retains final selection'
    Shot 'resized-end'
    Invoke-Aio type 'terminal setting'
    Invoke-Aio expect state palette.items=3
    Invoke-Aio expect state palette.selected=0
    Assert-Fit 'replacement query resets scroll'
    Invoke-Aio key End Enter
    Invoke-Aio expect state settings.key=terminal.minimum_contrast
    Invoke-Aio expect state settings.editing=true
    Search 'terminal settings contrast'
    Invoke-Aio expect state palette.items=1
    Assert-Fit 'one matching result'
    Shot 'single-result-highlights'
    $s = Read-State
    $panel = @($s['palette.panel'] -split ',' | ForEach-Object { [double]$_ })
    $scale = [double]$s['window.scale']
    $start = "$([int]($panel[0]+14*$scale)),$([int]($panel[1]+38*$scale))"
    $end = "$([int]($panel[0]+$panel[2]-14*$scale)),$([int]($panel[1]+38*$scale))"
    Invoke-Aio mouse drag $start $end --px
    Shot 'query-pointer-selection'
    Invoke-Aio type 'terminal setting'
    Invoke-Aio expect state 'palette.query=terminal setting'
    Invoke-Aio expect state palette.items=3
    Assert-Fit 'pointer selection replaced entire query'
    Invoke-Aio key Esc
    Search 'terminal settings zzz'
    Invoke-Aio expect state palette.items=0
    Invoke-Aio key Enter
    Invoke-Aio expect state palette.open=true
    Assert-Fit 'no matching results'
    Shot 'disabled-no-results'
    Invoke-Aio key Esc
    Invoke-Aio dpi 96
    Invoke-Aio resize 100x45
    Search 'setting'
    Assert-Fit 'normal layout'
    Invoke-Aio expect state palette.rows=8
    Shot 'normal-eight-rows'
    Invoke-Aio key Esc
} finally {
    if (-not $Prepared) { & $ctl --name $Name stop | Write-Output }
}
