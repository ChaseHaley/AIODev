param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'font-pickers'
function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $args : $result" }
}
function Read-State {
    $state = @{}
    foreach ($line in (& $ctl --name $name state)) {
        $pair = $line -split '=',2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}
function Open-Field([string]$Key) {
    if ((Read-State)['settings.open'] -eq 'true') {
        Invoke-Aio command settings.open
        Invoke-Aio command tab.close
    }
    Invoke-Aio command settings.open
    Invoke-Aio type $Key
    if ((Read-State)['settings.key'] -ne $Key) {throw "Could not select $Key"}
    Invoke-Aio key Tab
}
function Shot([string]$Label) {
    & "$repo/tools/win32.ps1" -Name $name -Shot "$repo/build/verify/$name/$Label.png" -Frame | Out-Null
}
Invoke-Aio launch --fresh
try {
    Open-Field font.family
    $monoCount = [int](Read-State)['settings.choice_count']
    if ($monoCount -lt 2) {throw 'No installed terminal fonts found'}
    Invoke-Aio expect state settings.popup=Choice
    Shot shell-fonts
    Invoke-Aio key Down Enter
    $shell = (Read-State)['terminal.font_family']
    if ($shell -ne (Read-State)['settings.value']) {throw 'Shell family did not apply'}
    Write-Output "PASS shell dropdown discovers $monoCount terminal families and applies $shell"
    Open-Field font.show_all
    Open-Field font.family
    $allCount = [int](Read-State)['settings.choice_count']
    if ($allCount -le $monoCount) {throw 'Show All Fonts did not expand the list'}
    Invoke-Aio key End
    Shot all-fonts-end
    Invoke-Aio key Esc
    if ((Read-State)['terminal.font_family'] -ne $shell) {throw 'Cancel changed shell font'}
    Write-Output "PASS Show All Fonts expands to $allCount families; End scrolls; Escape cancels"
    Open-Field interface.font_family
    if ([int](Read-State)['settings.choice_count'] -ne $allCount) {throw 'GUI picker lacks installed fonts'}
    Invoke-Aio key Down Enter
    $gui = (Read-State)['ui.font_family']
    if ($gui -ne (Read-State)['settings.value']) {throw 'GUI family did not apply'}
    if ((Read-State)['terminal.font_family'] -ne $shell) {throw 'GUI choice changed shell font'}
    Shot gui-font
    Invoke-Aio dpi 168
    Invoke-Aio key Enter
    Invoke-Aio key End
    Shot gui-font-high-dpi
    Invoke-Aio key Esc
    Write-Output "PASS independent GUI family $gui applies, including high DPI"
    $persisted = Join-Path $repo "build/verify/$name/persisted.ini"
    Copy-Item -LiteralPath (Join-Path $repo "build/verify/$name/settings.ini") -Destination $persisted
    Invoke-Aio stop
    Invoke-Aio launch --settings $persisted
    Invoke-Aio expect state "ui.font_family=$gui"
    Invoke-Aio expect state "terminal.font_family=$shell"
    Write-Output 'PASS both font choices survive relaunch'
} finally {
    & $ctl --name $name stop | Out-Null
}
