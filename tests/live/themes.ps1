[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'visual-themes'
$directory = Join-Path $repo "build/verify/$name"
$path = Join-Path $directory 'settings.ini'
function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    $result | Write-Output
}
function Read-State {
    $lines = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect state.' }
    $state = @{}
    foreach ($line in $lines) { $pair = $line -split '=', 2; $state[$pair[0]] = $pair[1] }
    return $state
}
function Set-Option([string] $Key, [string] $Value) {
    $text = [IO.File]::ReadAllText($path)
    $pattern = '(?m)^' + [regex]::Escape($Key) + '\s*=.*$'
    if ($text -match $pattern) { $text = [regex]::Replace($text, $pattern, "$Key = $Value") }
    else { $text += "
$Key = $Value
" }
    [IO.File]::WriteAllText($path, $text)
}
function Shot([string] $Label) {
    Start-Sleep -Milliseconds 220
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Shot (Join-Path $directory "$Label.png")
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}
function Assert-Equal($Actual, $Expected, [string] $Label) {
    if ($Actual -ne $Expected) { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label=$Expected"
}
function Assert-Idle {
    Start-Sleep -Milliseconds 250
    $before = (Read-State)['frames.presented']
    Start-Sleep -Milliseconds 400
    Assert-Equal (Read-State)['frames.presented'] $before 'settled interface presents no frames'
    Invoke-Aio expect state ui.animating=false
}
Invoke-Aio launch --fresh
try {
    $session = (Read-State)['session.id']
    Invoke-Aio run 'function prompt { "T> " }; Clear-Host; Write-Output THEME_READY'
    foreach ($theme in @('studio','tide','ember')) {
        foreach ($mode in @('dark','light')) {
            Set-Option theme.name $theme
            Set-Option theme.mode $mode
            Invoke-Aio command settings.reload
            Invoke-Aio expect state "theme.name=$theme"
            Invoke-Aio expect state "theme.mode=$mode"
            Invoke-Aio expect state "session.id=$session"
            Invoke-Aio expect text THEME_READY
            Shot "$theme-$mode-pane"
            Invoke-Aio key Ctrl+Shift+P
            Invoke-Aio expect state palette.open=true
            Shot "$theme-$mode-palette"
            Assert-Idle
            Invoke-Aio key Esc
            Invoke-Aio key Ctrl+Shift+F
            Invoke-Aio type THEME_READY
            Invoke-Aio expect state 'find.matches=1 match'
            Shot "$theme-$mode-find"
            Invoke-Aio key Esc
            Invoke-Aio key 'Ctrl+,'
            Invoke-Aio type theme.mode
            Invoke-Aio key Tab
            Shot "$theme-$mode-settings"
            Invoke-Aio key Tab
            Shot "$theme-$mode-search-focus"
            Assert-Idle
            Invoke-Aio command tab.close
        }
    }
    Set-Option theme.name studio
    Set-Option theme.mode dark
    Set-Option theme.custom.ocean.base 'studio-dark'
    Set-Option theme.custom.ocean.background '#102030'
    Set-Option theme.custom.ocean.foreground '#fedcba'
    Set-Option theme.custom.ocean.tab_bar '#203040'
    Set-Option theme.name ocean
    Invoke-Aio command settings.reload
    Invoke-Aio expect state terminal.background=#102030
    Invoke-Aio expect state "session.id=$session"
    Shot terminal-overrides
    Invoke-Aio key Ctrl+Shift+P
    Shot independent-interface-colors
    Invoke-Aio key Esc
    Set-Option theme.name studio
    Invoke-Aio command settings.reload
    foreach ($count in @(1,2,4)) {
        while ([int](Read-State)['panes.count'] -lt $count) {
            if ([int](Read-State)['panes.count'] -eq 1) { Invoke-Aio command pane.split_right }
            else { Invoke-Aio command pane.split_down }
            Invoke-Aio wait text 'PS '
        }
        foreach ($gap in @(0,5,24)) {
            foreach ($radius in @(0,7)) {
                Set-Option pane.gap $gap
                Set-Option pane.corner_radius $radius
                Invoke-Aio command settings.reload
                Invoke-Aio expect state "panes.count=$count"
                if ($count -gt 1) {
                    $state = Read-State
                    $rect = $state['pane.0.rect'] -split ','
                    $x = [int]([double]$rect[0]+[double]$rect[2]+[math]::Max(1,$gap)/2)
                    $y = [int]([double]$rect[1]+[double]$rect[3]/2)
                    Invoke-Aio mouse drag "$x,$y" "$($x+10),$y" --px
                }
                Shot "panes-$count-gap-$gap-radius-$radius"
            }
        }
    }
    Set-Option pane.gap 5
    Set-Option pane.corner_radius 7
    Set-Option shell.command 'aiodev_missing_visual_fixture.exe'
    Invoke-Aio command settings.reload
    Invoke-Aio command terminal.restart_shell
    Invoke-Aio expect state session.status=failed
    foreach ($mode in @('dark','light')) {
        Set-Option theme.mode $mode
        Invoke-Aio command settings.reload
        Shot "failed-pane-$mode"
    }
    Set-Option theme.name tide
    Set-Option theme.mode dark
    Invoke-Aio command settings.reload
    Shot failed-pane-tide
    Write-Output 'PASS six themes, terminal overrides, pane matrix, controls and failure surfaces'
} finally {
    & $ctl --name $name stop | Write-Output
}
