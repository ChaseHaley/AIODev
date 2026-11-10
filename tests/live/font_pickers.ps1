param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'font-pickers'
# A headless instance sees only the bundled fonts (WORK-351): Cascadia Code stands in for the installed
# monospace Consolas and Selawik for the proportional Segoe UI.
$headless = $env:AIOCTL_HEADLESS -eq '1'
$mono = if ($headless) { 'Cascadia Code' } else { 'Consolas' }
$proportional = if ($headless) { 'Selawik' } else { 'Segoe' }
$proportionalFull = if ($headless) { 'Selawik' } else { 'Segoe ui' }
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
    $beforeSearch = (Read-State)['terminal.font_family']
    Invoke-Aio type $mono
    Invoke-Aio expect state "settings.choice_query=$mono"
    Invoke-Aio expect state settings.choice_matches=1
    Invoke-Aio expect state settings.filter=font.family
    Invoke-Aio expect state "terminal.font_family=$beforeSearch"
    Shot shell-search
    Invoke-Aio key Enter
    $shell = (Read-State)['terminal.font_family']
    if ($shell -ne (Read-State)['settings.value']) {throw 'Shell family did not apply'}
    Write-Output "PASS shell dropdown discovers $monoCount terminal families and applies $shell"
    Open-Field font.family
    Invoke-Aio key Tab Space
    Invoke-Aio expect state settings.popup=Choice
    $allCount = [int](Read-State)['settings.choice_count']
    if ($allCount -le $monoCount) {throw 'Show All Fonts did not expand the list'}
    Invoke-Aio key Tab
    Invoke-Aio type $proportional
    Invoke-Aio key Tab Space
    Invoke-Aio expect state "settings.choice_query=$proportional"
    Invoke-Aio expect state settings.choice_matches=0
    Invoke-Aio expect state settings.popup=Choice
    Invoke-Aio expect state "terminal.font_family=$shell"
    Shot shell-filtered-empty
    Invoke-Aio key Space
    Invoke-Aio expect state "settings.choice_query=$proportional"
    if ([int](Read-State)['settings.choice_matches'] -lt 1) {throw 'Toggle did not refilter the current search'}
    Invoke-Aio key Tab Ctrl+A Backspace Ctrl+End
    Shot all-fonts-end
    Invoke-Aio key Esc
    if ((Read-State)['terminal.font_family'] -ne $shell) {throw 'Cancel changed shell font'}
    Write-Output "PASS Show All Fonts expands to $allCount families; Ctrl+End scrolls; Escape cancels"
    Open-Field interface.font_family
    # The default interface family (Segoe UI Variable) is not bundled, so headless the picker also keeps
    # the current value as a choice, as it does for any family that is not installed.
    $guiCount = if ($headless) { $allCount + 1 } else { $allCount }
    if ([int](Read-State)['settings.choice_count'] -ne $guiCount) {throw 'GUI picker lacks installed fonts'}
    Invoke-Aio type no-such-font-xyz
    Invoke-Aio expect state settings.choice_matches=0
    Invoke-Aio key Enter
    Invoke-Aio expect state settings.popup=Choice
    Shot no-fonts-found
    Invoke-Aio key Ctrl+A Backspace
    Invoke-Aio expect state "settings.choice_matches=$guiCount"
    Invoke-Aio type $proportionalFull
    Invoke-Aio expect state "settings.choice_query=$proportionalFull"
    Shot gui-search
    Invoke-Aio key Enter
    $gui = (Read-State)['ui.font_family']
    if ($gui -ne (Read-State)['settings.value']) {throw 'GUI family did not apply'}
    if ((Read-State)['terminal.font_family'] -ne $shell) {throw 'GUI choice changed shell font'}
    Shot gui-font
    Invoke-Aio dpi 168
    Invoke-Aio key Enter
    Invoke-Aio type 'nerd font'
    Shot gui-font-high-dpi
    Invoke-Aio key Esc
    Write-Output 'PASS both pickers search without changing settings search; empty result cannot save; clear restores list'
    Write-Output "PASS independent GUI family $gui applies, including high DPI"
    $persisted = Join-Path $repo "build/verify/$name/persisted.ini"
    Copy-Item -LiteralPath (Join-Path $repo "build/verify/$name/settings.ini") -Destination $persisted
    Invoke-Aio stop
    Invoke-Aio launch --settings $persisted
    Invoke-Aio expect state "ui.font_family=$gui"
    Invoke-Aio expect state "terminal.font_family=$shell"
    Open-Field font.family
    if ([int](Read-State)['settings.choice_count'] -ne $allCount) {throw 'Show All preference did not persist'}
    Invoke-Aio dpi 168
    Shot shell-toggle-high-dpi
    Invoke-Aio key Esc
    Write-Output 'PASS both font choices survive relaunch'
} finally {
    & $ctl --name $name stop | Out-Null
}
