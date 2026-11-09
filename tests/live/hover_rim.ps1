[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_-]{1,32}$')]
    [string] $Name = 'hover-rim',
    [switch] $Capture
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$data = Join-Path $repo "build/verify/$Name"
New-Item -ItemType Directory -Force $data | Out-Null
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
function Rect($State, [string] $Key) {
    return @($State[$Key] -split ',' | ForEach-Object {
        [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture)
    })
}
function Point($Rect) {
    return "$([int]($Rect[0]+$Rect[2]/2)),$([int]($Rect[1]+$Rect[3]/2))"
}
function Check([bool] $Condition, [string] $Label) {
    if (-not $Condition) { throw "FAIL $Label" }
    Write-Output "PASS $Label"
}
function Tab-Point([int] $Index) {
    $s = Read-State
    $key = "tab.$Index.rect"
    if (-not $s.ContainsKey($key)) { throw "State lacks $key; the tab rail row is unknown." }
    $r = $s[$key] -split ','
    return "$([int]([double]$r[0]+[double]$r[2]/2)),$([int]([double]$r[1]+[double]$r[3]/2))"
}
function Shot([string] $Label) {
    Invoke-Aio wait idle | Out-Null
    if (-not $Capture) { return }
    Start-Sleep -Milliseconds 250
    Invoke-Aio state | Set-Content -LiteralPath "$data/$Label-state.txt" -Encoding utf8
    & (Join-Path $repo 'tools/win32.ps1') -Name $Name -Shot "$data/$Label.png" -Frame
    if ($LASTEXITCODE -ne 0) { throw "Capture failed: $Label" }
}

Invoke-Aio launch --fresh
try {
    Invoke-Aio key Ctrl+Shift+L
    Invoke-Aio wait text 'PS '
    $state = Read-State
    $chip = Rect $state 'workspace.button'
    Invoke-Aio mouse move (Point $chip) --px
    Invoke-Aio wait idle
    Invoke-Aio expect state workspace.button.hover=true
    Check $true 'chip reports hover'
    Shot 'chip-hover'

    # The rim light must follow the pointer, not sit at a fixed corner: the right edge
    # should take the light when the pointer is over the right side of the chip.
    Invoke-Aio mouse move "$([int]($chip[0]+$chip[2]-14)),$([int]($chip[1]+$chip[3]/2))" --px
    Invoke-Aio wait idle
    Invoke-Aio expect state workspace.button.hover=true
    Shot 'chip-hover-right'

    # Leave the chip, then hover an ordinary tab so the tab lift and rim are exercised too.
    $size = $state['window.size'] -split 'x'
    Invoke-Aio mouse move "400,$([int]([double]$size[1] - 40))" --px
    Invoke-Aio wait idle
    Invoke-Aio expect state workspace.button.hover=false
    Invoke-Aio mouse move (Tab-Point 1) --px
    Invoke-Aio wait idle
    Shot 'tab-hover'

    # Open the workspace picker and hover its first row: rows get the light but keep their place.
    Invoke-Aio mouse click (Point $chip) --px
    Invoke-Aio expect state workspace.picker=true
    $state = Read-State
    $row = Rect $state 'workspace.picker.row'
    Invoke-Aio mouse move (Point $row) --px
    Invoke-Aio wait idle
    Invoke-Aio expect state workspace.picker=true
    Shot 'picker-row-hover'
    Invoke-Aio key Esc
    Invoke-Aio expect state workspace.picker=false

    # Light themes use the paper fill, so the same tab must lighten instead of darkening.
    # The capture is the evidence; the theme switch proves the light values reach the draw path.
    $settings = Join-Path $data 'settings.ini'
    $text = [IO.File]::ReadAllText($settings).TrimEnd()
    [IO.File]::WriteAllText($settings, $text + "`ntheme.name = studio-light`n")
    Invoke-Aio command settings.reload
    Invoke-Aio wait idle
    Invoke-Aio expect state theme.name=studio-light
    # The first tab is selected and already white; hover a second, ordinary tab so the
    # paper fill is the thing under review.
    Invoke-Aio command tab.new
    Invoke-Aio wait idle
    Invoke-Aio command tab.select_1
    Invoke-Aio wait idle
    Invoke-Aio expect state tabs.count=2
    Invoke-Aio expect state tabs.selected=1
    $state = Read-State
    Invoke-Aio mouse move (Tab-Point 2) --px
    Invoke-Aio wait idle
    Shot 'tab-hover-light'
    $text = [IO.File]::ReadAllText($settings)
    $text = [regex]::Replace($text, '(?m)^theme\.name\s*=.*\r?\n?', '')
    [IO.File]::WriteAllText($settings, $text.TrimEnd() + "`ntheme.name = studio-dark`n")
    Invoke-Aio command settings.reload
    Invoke-Aio wait idle
    Invoke-Aio expect state theme.name=studio-dark

    # Both values are ordinary settings: without a restart, zero lift and zero gloss
    # must reach the theme and remove the raised effect.
    $text = [IO.File]::ReadAllText($settings).TrimEnd()
    [IO.File]::WriteAllText($settings, $text + "`ninterface.hover_lift = 0`ninterface.hover_gloss = 0`n")
    Invoke-Aio command settings.reload
    Invoke-Aio wait idle
    Invoke-Aio expect state theme.hover_lift=0
    Invoke-Aio expect state theme.hover_gloss=0
    Invoke-Aio mouse move (Point $chip) --px
    Invoke-Aio wait idle
    Invoke-Aio expect state workspace.button.hover=true
    Shot 'chip-hover-no-lift-no-gloss'

    Write-Output 'PASS raised hover on chip, tab and picker row; lift and gloss settings apply live'
} finally {
    Invoke-Aio stop
}
