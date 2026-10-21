[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_-]{1,32}$')]
    [string] $Name = 'work142-icon-grid',
    [switch] $Capture
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$data = Join-Path $repo "build/verify/$Name"

function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}
function Read-State {
    $out = Invoke-Aio state
    $state = @{}
    foreach ($line in $out) { $pair = $line -split '=', 2; $state[$pair[0]] = $pair[1].Trim('"') }
    return $state
}
function Rect($State, $Key) {
    return @($State[$Key] -split ',' | ForEach-Object {
        [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture)
    })
}
function Click-Rect($Rect) {
    Invoke-Aio mouse click "$([int]($Rect[0]+$Rect[2]/2)),$([int]($Rect[1]+$Rect[3]/2))" --px
}
function Check([bool] $Condition, [string] $Label) {
    if (-not $Condition) { throw "FAIL $Label" }
    Write-Output "PASS $Label"
}
function Shot([string] $Label) {
    Invoke-Aio wait frame | Out-Null
    Invoke-Aio state | Set-Content -LiteralPath "$data/$Label-state.txt" -Encoding utf8
    if ($Capture) {
        & (Join-Path $repo 'tools/win32.ps1') -Name $Name -Shot "$data/$Label.png" -Frame
        if ($LASTEXITCODE -ne 0) { throw "Read-only capture failed: $Label" }
    }
}
function Check-Layout([string] $Label) {
    $s = Read-State
    $r, $field = (Rect $s 'workspace.picker.rect'), (Rect $s 'workspace.picker.field')
    $size = $s['window.size'] -split 'x'
    $scale = [double]::Parse($s['window.scale'], [Globalization.CultureInfo]::InvariantCulture)
    Check ($r[0] -eq 5*$scale -and $r[1] -eq 40*$scale -and
        $r[0]+$r[2] -le [double]$size[0] -and $r[1]+$r[3] -le [double]$size[1]) "$Label menu anchor and fit"
    Invoke-Aio key End
    $cell = Rect (Read-State) 'workspace.picker.row'
    Check ($cell[2] -eq 44*$scale -and $cell[3] -eq 44*$scale -and
        $cell[1]+$cell[3] -lt $field[1]) "$Label last grid cell above custom field"
    Invoke-Aio key Tab Tab
    $apply = Rect (Read-State) 'workspace.picker.row'
    Check ($apply[1] -gt $field[1]+$field[3] -and
        $apply[1]+$apply[3] -le $r[1]+$r[3]) "$Label Apply Custom Emoji below field and inside menu"
    Shot $Label
}

# aioctl launches with --no-activate; every interaction below uses app control paths.
Invoke-Aio launch --fresh
try {
    Invoke-Aio wait text 'PS '
    $initial = Read-State
    $workspace, $session = $initial['workspace.id'], $initial['session.id']
    Invoke-Aio command workspace.change_icon
    Invoke-Aio expect state workspace.picker.icons=true
    $count = [int](Read-State)['workspace.picker.count']-2
    Check ($count -eq 10) 'ten presets and separate custom field/apply stops'
    $firstCell = Rect (Read-State) 'workspace.picker.row'
    Invoke-Aio key Right Down Up
    Invoke-Aio expect state workspace.picker.selected=1
    $nextCell = Rect (Read-State) 'workspace.picker.row'
    Check ($nextCell[0] -gt $firstCell[0] -and $nextCell[1] -eq $firstCell[1]) 'horizontal grid navigation'
    Invoke-Aio key Enter
    Invoke-Aio expect state workspace.icon.preset=1
    Invoke-Aio expect state workspace.picker.icons=false
    Invoke-Aio key Esc

    Invoke-Aio command workspace.change_icon
    Invoke-Aio key End
    $lastCell = Rect (Read-State) 'workspace.picker.row'
    Invoke-Aio mouse move "$([int]($lastCell[0]+22)),$([int]($lastCell[1]+22))" --px
    Invoke-Aio expect state "workspace.picker.selected=$($count-1)"
    Click-Rect $lastCell
    Invoke-Aio expect state "workspace.icon.preset=$($count-1)"
    Invoke-Aio key Esc

    $emoji = -join (@(0x1F469, 0x1F3FD, 0x200D, 0x1F4BB) | ForEach-Object { [char]::ConvertFromUtf32($_) })
    Invoke-Aio command workspace.change_icon
    $field = Rect (Read-State) 'workspace.picker.field'
    Click-Rect $field
    Invoke-Aio expect state "workspace.picker.selected=$count"
    Invoke-Aio type $emoji
    Invoke-Aio expect state "workspace.picker.query=$emoji"
    Invoke-Aio focus out
    Invoke-Aio expect state workspace.picker.icons=true
    Invoke-Aio focus in
    Invoke-Aio key Esc
    Invoke-Aio expect state workspace.icon.emoji=
    Invoke-Aio key Esc

    Invoke-Aio command workspace.change_icon
    Invoke-Aio type $emoji
    Invoke-Aio key Tab
    Invoke-Aio expect state "workspace.picker.selected=$($count+1)"
    Click-Rect (Rect (Read-State) 'workspace.picker.row')
    Invoke-Aio expect state "workspace.icon.emoji=$emoji"
    Invoke-Aio key Esc
    Invoke-Aio command workspace.change_icon
    Invoke-Aio expect state "workspace.picker.selected=$count"
    Invoke-Aio expect state "workspace.picker.query=$emoji"
    Invoke-Aio type 'two words'
    Invoke-Aio key Enter
    Invoke-Aio expect state workspace.picker.icons=true
    Invoke-Aio expect state "workspace.icon.emoji=$emoji"
    Invoke-Aio key Ctrl+A Backspace Enter
    Invoke-Aio expect state workspace.picker.icons=true
    Invoke-Aio expect state "workspace.icon.emoji=$emoji"
    Invoke-Aio type '123456789012345678901234567890123'
    Invoke-Aio key Enter
    Invoke-Aio expect state workspace.picker.icons=true
    Invoke-Aio expect state "workspace.icon.emoji=$emoji"
    Invoke-Aio key Ctrl+A
    $flag = -join (@(0x1F3F3, 0xFE0F, 0x200D, 0x1F308) | ForEach-Object { [char]::ConvertFromUtf32($_) })
    Invoke-Aio type $flag
    Invoke-Aio key Enter
    Invoke-Aio expect state "workspace.icon.emoji=$flag"
    Invoke-Aio key Esc

    foreach ($mode in @('dark', 'light')) {
        $path = Join-Path $data 'settings.ini'
        $text = [IO.File]::ReadAllText($path)
        $text = [regex]::Replace($text, '(?m)^theme.mode\s*=.*\r?\n?', '')
        [IO.File]::WriteAllText($path, $text.TrimEnd()+"`ntheme.mode = $mode`n")
        Invoke-Aio command settings.reload
        foreach ($dpi in @(96, 144, 168, 192)) {
            Invoke-Aio dpi $dpi
            Invoke-Aio resize 46x20
            Invoke-Aio command workspace.change_icon
            Invoke-Aio key Ctrl+N
            Invoke-Aio expect state "workspace.picker.selected=$($count+1)"
            Invoke-Aio key Ctrl+N
            Invoke-Aio expect state workspace.picker.selected=0
            Check-Layout "$mode-$dpi"
            Invoke-Aio key Esc Esc
        }
    }
    Invoke-Aio dpi 96
    Invoke-Aio resize 25x10
    Invoke-Aio command workspace.change_icon
    Invoke-Aio key Ctrl+N Ctrl+N
    Invoke-Aio expect state workspace.picker.selected=0
    Invoke-Aio mouse wheel '30,100' -1 --px
    Invoke-Aio expect state workspace.picker.selected=1
    Check-Layout 'short-scrolled'
    Invoke-Aio key Esc Esc
    Invoke-Aio command workspace.change_icon
    Invoke-Aio mouse click '1,41' --px
    Invoke-Aio expect state workspace.picker=false
    Invoke-Aio expect state "workspace.id=$workspace"
    Invoke-Aio expect state "session.id=$session"
    Invoke-Aio expect state workspaces.count=1
    Write-Output 'PASS compact workspace grid, key/pointer input, Unicode validation/apply/cancel, DPI/themes and stable identity'
} finally {
    Invoke-Aio stop
}
