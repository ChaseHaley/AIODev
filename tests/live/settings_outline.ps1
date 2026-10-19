param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'settings-outline'
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}
function Read-State {
    $out = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $s = @{}
    foreach ($line in $out) { $pair = $line -split '=',2; $s[$pair[0]] = $pair[1].Trim('"') }
    return $s
}
function Assert-Value($Actual, $Expected, $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Shot($Label) {
    & "$repo/tools/win32.ps1" -Name $name -Shot "$repo/build/verify/$name/$Label.png" -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}
Invoke-Aio launch --fresh
try {
    Invoke-Aio wait text 'PS '
    Invoke-Aio dpi 96
    Invoke-Aio resize 160x40
    Invoke-Aio command settings.open
    $before = Read-State
    Invoke-Aio key Alt+Down
    Assert-Value (Read-State)['settings.group'] 1 'keyboard jumps to the next group'
    Assert-Value (Read-State)['settings.filter'] '' 'outline jump keeps the whole page'
    Invoke-Aio key Alt+Up
    Assert-Value (Read-State)['settings.group'] 0 'keyboard jumps back'
    Shot outline-dark
    Invoke-Aio type font
    Invoke-Aio key Esc
    Assert-Value (Read-State)['settings.filter'] '' 'Escape clears search without a mouse'
    Invoke-Aio type no-such-setting-xyz
    Assert-Value (Read-State)['settings.group'] -1 'no matches has no active group'
    $state = Read-State
    $rect = $state["pane.$($state['panes.focused']).rect"] -split ','
    $left, $top = [double]$rect[0], [double]$rect[1]
    Invoke-Aio mouse click "$([int]($left+230)),$([int]($top+69))" --px
    Assert-Value (Read-State)['settings.filter'] '' 'clear button clears a no-match search'
    Invoke-Aio mouse click "$([int]($left+80)),$([int]($top+143))" --px
    Assert-Value (Read-State)['settings.filter'] '' 'clicking an outline entry never filters'
    if ([int](Read-State)['settings.scroll'] -le 0) { throw 'Outline click did not scroll the page.' }
    & "$repo/tools/win32.ps1" -Name $name -Resize 560x800 | Out-Null
    Shot narrow
    Invoke-Aio dpi 168
    Shot high-dpi
    Invoke-Aio dpi 96
    & "$repo/tools/win32.ps1" -Name $name -Resize 1400x900 | Out-Null
    $path = "$repo/build/verify/$name/settings.ini"
    [IO.File]::AppendAllText($path, "`ntheme.mode = light`n")
    Invoke-Aio command settings.reload
    Shot outline-light
    Write-Output 'PASS settings outline navigation'
} finally { & $ctl --name $name stop | Out-Null }
