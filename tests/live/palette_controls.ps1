[CmdletBinding()]
param(
    [string] $Repository = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [ValidatePattern('^[A-Za-z0-9_-]{1,32}$')] [string] $Name = 'palette-controls-work123',
    [switch] $Prepared,
    [switch] $Capture
)

# Settings change in place from the palette: a toggle, a slider, a choice list and a text entry,
# while Enter still jumps to the setting in Settings.
$ErrorActionPreference = 'Stop'
$ctl = Join-Path $Repository 'build/aioctl.exe'
$directory = Join-Path $Repository "build/verify/$Name"
New-Item -ItemType Directory -Force $directory | Out-Null

function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}

function Shot([string] $Label) {
    Invoke-Aio state | Set-Content -LiteralPath "$directory/$Label-state.txt"
    if (-not $Capture) { return }
    Start-Sleep -Milliseconds 250
    & (Join-Path $Repository 'tools/win32.ps1') -Name $Name -Shot "$directory/$Label.png" -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Screenshot failed: $Label" }
}

function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Aio state)) {
        $pair = $line -split '=', 2
        if ($pair.Count -eq 2) { $state[$pair[0]] = $pair[1].Trim('"') }
    }
    return $state
}

function Search([string] $Query, [string] $Key) {
    Invoke-Aio key Ctrl+A Backspace
    Invoke-Aio type $Query
    Invoke-Aio expect state "palette.item=$Key"
}

if (-not $Prepared) { Invoke-Aio launch --fresh --size 120x36 }
try {
    Invoke-Aio command app.palette_settings
    Shot 'settings-list'

    Search 'cursor blink' 'cursor.blink'
    Invoke-Aio expect state 'palette.value=false'
    Invoke-Aio key Alt+Right
    Invoke-Aio expect state 'palette.value=true'
    Invoke-Aio expect state 'palette.open=true'
    Write-Output 'PASS Alt+Right turns a toggle on and keeps the palette open'
    Shot 'toggle-on'

    Search 'pane gap' 'pane.gap'
    $defaultGap = [int](Read-State)['palette.value']
    Invoke-Aio key Alt+Right Alt+Right
    Invoke-Aio expect state "palette.value=$($defaultGap + 2)"
    Write-Output 'PASS Alt+Right steps a slider'
    Shot 'slider-modified'

    # The first result is the list's first row; its reset button is the row's last 34 DIPs.
    $state = Read-State
    $list = $state['palette.list'] -split ','
    $scale = [double]$state['palette.row_height'] / 40
    $x = [double]$list[0] + [double]$list[2] - 21 * $scale
    $y = [double]$list[1] + 20 * $scale
    Invoke-Aio mouse click "$([int]$x),$([int]$y)" --px
    Invoke-Aio expect state "palette.value=$defaultGap"
    Invoke-Aio expect state 'palette.open=true'
    Write-Output 'PASS the reset button restores the default in place'

    Search 'cursor style' 'cursor.style'
    Invoke-Aio key Ctrl+Enter
    Invoke-Aio expect state 'palette.edit=Choice'
    Shot 'choice-open'
    Invoke-Aio key Down Enter
    Invoke-Aio expect state 'palette.edit=None'
    Invoke-Aio expect state 'palette.value=bar'
    Write-Output 'PASS the choice list opens and chooses in place'

    Search 'shell font' 'font.family'
    Invoke-Aio key Ctrl+Enter
    Invoke-Aio expect state 'palette.edit=Choice'
    Invoke-Aio key Esc
    Invoke-Aio expect state 'palette.edit=None'
    Invoke-Aio expect state 'palette.open=true'
    Write-Output 'PASS Escape closes only the list'
    Invoke-Aio key Ctrl+Enter
    Invoke-Aio type 'consol'
    Shot 'font-filter'
    Invoke-Aio key Enter
    Invoke-Aio expect state 'palette.value=Consolas'
    Write-Output 'PASS typing filters the font list'

    Search 'ignore status from' 'status.ignore_apps'
    Invoke-Aio key Ctrl+Enter
    Invoke-Aio expect state 'palette.edit=Text'
    Invoke-Aio type 'less'
    Shot 'text-entry'
    Invoke-Aio key Enter
    Invoke-Aio expect state 'palette.value=less'
    Write-Output 'PASS a text entry saves on Enter'

    Search 'pane gap' 'pane.gap'
    Invoke-Aio key Enter
    Invoke-Aio expect state 'palette.open=false'
    Invoke-Aio expect state 'settings.key=pane.gap'
    Write-Output 'PASS Enter still jumps to the setting'
    Shot 'jumped'
}
finally {
    if (-not $Prepared) { & $ctl --name $Name stop | Write-Output }
}
