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
function Rect($State, $Key) { return @($State[$Key] -split ',' | ForEach-Object { [double]$_ }) }
# Wide pages center the outline and list together; pages too narrow for the full list keep the left margin.
function Assert-Centered($Label) {
    $state = Read-State
    $scale = [double]$state['window.scale']
    $pane = Rect $state "pane.$($state['panes.focused']).rect"
    $outline = Rect $state 'settings.outline_rect'
    $list = Rect $state 'settings.list_rect'
    $left = $outline[0]-$pane[0]
    $right = $pane[0]+$pane[2]-$list[0]-$list[2]
    if ($outline[2] -le 0) { throw "$Label has no outline column." }
    if ([math]::Abs($list[2]-960*$scale) -lt 0.5) {
        if ([math]::Abs($left-$right) -gt 1) { throw "$Label margins $left and $right are not centered." }
    } elseif ([math]::Abs($left-24*$scale) -gt 0.5 -or $right -lt 24*$scale-0.5) {
        throw "$Label does not fit inside its margins: $left, $right."
    }
    Write-Output "PASS $Label margins $([int]$left),$([int]$right) at width $([int]$pane[2])"
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
    Assert-Centered 'default window'
    $state = Read-State
    $search = Rect $state 'settings.search_rect'
    $outline = Rect $state 'settings.outline_rect'
    Invoke-Aio mouse click "$([int]($search[0]+$search[2]-17)),$([int]($search[1]+$search[3]/2))" --px
    Assert-Value (Read-State)['settings.filter'] '' 'clear button clears a no-match search'
    Invoke-Aio mouse click "$([int]($outline[0]+56)),$([int]($outline[1]+45))" --px
    Assert-Value (Read-State)['settings.filter'] '' 'clicking an outline entry never filters'
    if ([int](Read-State)['settings.scroll'] -le 0) { throw 'Outline click did not scroll the page.' }
    & "$repo/tools/win32.ps1" -Name $name -Resize 560x800 | Out-Null
    Shot narrow
    Invoke-Aio dpi 168
    Shot high-dpi
    Invoke-Aio dpi 96
    & "$repo/tools/win32.ps1" -Name $name -Resize 1000x800 | Out-Null
    Assert-Centered 'below full list width'
    Shot below-full-width
    $width = [double]((Read-State)['window.size'] -split 'x')[0]
    Invoke-Aio mouse click "$([int]($width-69)),20" --px
    Invoke-Aio expect state window.maximized=true
    Assert-Centered 'maximized'
    Shot maximized
    Invoke-Aio type font.size
    $state = Read-State
    $slider = Rect $state 'settings.slider'
    $point = "$([int]($slider[0]+$slider[2]*0.25)),$([int]($slider[1]+$slider[3]/2))"
    Invoke-Aio mouse click $point --px
    if ((Read-State)['settings.value'] -eq $state['settings.value']) { throw 'Centered slider ignored the click.' }
    Write-Output 'PASS centered slider takes the click where it is drawn'
    Invoke-Aio key Esc
    if ((Read-State)['settings.filter'] -ne '') { Invoke-Aio key Esc }
    Assert-Value (Read-State)['settings.filter'] '' 'Escape clears the centered search'
    Invoke-Aio dpi 168
    Assert-Centered 'maximized high DPI'
    Shot maximized-high-dpi
    Invoke-Aio dpi 96
    $width = [double]((Read-State)['window.size'] -split 'x')[0]
    Invoke-Aio mouse click "$([int]($width-69)),20" --px
    Invoke-Aio expect state window.maximized=false
    & "$repo/tools/win32.ps1" -Name $name -Resize 1400x900 | Out-Null
    $path = "$repo/build/verify/$name/settings.ini"
    [IO.File]::AppendAllText($path, "`ntheme.mode = light`n")
    Invoke-Aio command settings.reload
    Shot outline-light
    Write-Output 'PASS settings outline navigation'
} finally { & $ctl --name $name stop | Out-Null }
