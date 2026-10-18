[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'pane-headers'
$directory = Join-Path $repo "build/verify/$name"
$path = Join-Path $directory 'settings.ini'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AioHeaderAnimations {
    [DllImport("user32.dll", SetLastError=true)]
    static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, IntPtr wparam, IntPtr lparam, uint flags, uint timeout, out IntPtr result);
    public static void Notify(int pid) {
        var window = System.Diagnostics.Process.GetProcessById(pid).MainWindowHandle;
        IntPtr result;
        if (window == IntPtr.Zero || SendMessageTimeoutW(window, 0x1a, new IntPtr(0x1043), IntPtr.Zero, 2, 1000, out result) == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception();
    }
    [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
    static extern bool Get(uint action, uint parameter, out int value, uint flags);
    [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
    static extern bool Set(uint action, uint parameter, IntPtr value, uint flags);
    public static bool Read() {
        int value;
        if (!Get(0x1042, 0, out value, 0)) throw new System.ComponentModel.Win32Exception();
        return value != 0;
    }
    public static void Write(bool value) {
        if (!Set(0x1043, 0, new IntPtr(value ? 1 : 0), 2)) throw new System.ComponentModel.Win32Exception();
        if (Read() != value) throw new Exception("Windows did not apply the animation preference");
    }
}
'@
function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    $result | Write-Output
}
function Read-State {
    $lines = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect state.' }
    $values = @{}
    foreach ($line in $lines) { $pair = $line -split '=', 2; $values[$pair[0]] = $pair[1] }
    return $values
}
function Assert-Equal($Actual, $Expected, [string] $Label) {
    if ($Actual -ne $Expected) { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label=$Expected"
}
function Set-Option([string] $Key, [string] $Value) {
    $text = [IO.File]::ReadAllText($path)
    $pattern = '(?m)^' + [regex]::Escape($Key) + '\s*=.*$'
    if ($text -match $pattern) { $text = [regex]::Replace($text, $pattern, "$Key = $Value") }
    else { $text += "`n$Key = $Value`n" }
    [IO.File]::WriteAllText($path, $text)
}
function Shot([string] $Label) {
    Start-Sleep -Milliseconds 250
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Shot (Join-Path $directory "$Label.png")
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}
function Header-Button([int] $Index) {
    $s = Read-State
    $r = $s["pane.$($s['panes.focused']).rect"] -split ',' | ForEach-Object { [double]$_ }
    $scale = [double]$s['window.scale']
    # Right-to-left close, zoom, split-down and split-right, using the accepted22-DIP controls.
    $x = [int]($r[0]+$r[2]-(16+24*(3-$Index))*$scale)
    $y = [int]($r[1]+14*$scale)
    Invoke-Aio mouse click "$x,$y" --px
}
function Assert-Origin {
    $s = Read-State
    $r = $s["pane.$($s['panes.focused']).rect"] -split ',' | ForEach-Object { [double]$_ }
    $origin = $s['grid.origin'] -split ',' | ForEach-Object { [double]$_ }
    Assert-Equal $origin[0] ($r[0]+[double]$s['grid.padding']) 'grid x follows pane'
    Assert-Equal $origin[1] ($r[1]+[double]$s['panes.header_height']+[double]$s['grid.padding']) 'grid y reserves header'
    $cell = $s['grid.cell'] -split 'x' | ForEach-Object { [double]$_ }
    $grid = $s['grid.size'] -split 'x' | ForEach-Object { [int]$_ }
    $rows = [math]::Max(1,[math]::Floor(($r[3]-[double]$s['panes.header_height']-2*[double]$s['grid.padding'])/$cell[1]))
    Assert-Equal $grid[1] $rows 'terminal rows exclude header and padding'
}
function Assert-Idle {
    Start-Sleep -Milliseconds 300
    $frames = (Read-State)['frames.presented']
    Start-Sleep -Milliseconds 450
    Assert-Equal (Read-State)['frames.presented'] $frames 'settled header draws no extra frames'
    Invoke-Aio expect state ui.animating=false
}
$originalAnimations = [AioHeaderAnimations]::Read()
[AioHeaderAnimations]::Write($false)
Invoke-Aio launch --fresh
try {
    Invoke-Aio expect state ui.animations=false
    Invoke-Aio expect state panes.header_height=0
    Invoke-Aio command pane.split_right
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state session.header.directory_source=launch
    Invoke-Aio run 'function prompt { "H> " }; $esc=[char]27; [Console]::Write("${esc}]2;HEADER_TITLE${esc}\${esc}]7;file:///C:/Header%20Test${esc}\"); Write-Output ("HEADER_"+"READY")'
    Invoke-Aio wait text HEADER_READY
    Invoke-Aio expect state session.header.title=HEADER_TITLE
    Invoke-Aio expect state 'session.header.directory=C:\Header Test'
    Invoke-Aio expect state session.header.directory_source=shell
    Invoke-Aio expect state 'session.header.icon=>_'
    Invoke-Aio expect state panes.header_height=28
    $session = (Read-State)['session.id']
    Assert-Origin
    Set-Option shell.command 'cmd.exe /d'
    Set-Option shell.directory 'C:\Windows'
    Invoke-Aio command settings.reload
    Invoke-Aio expect state "session.id=$session"
    Invoke-Aio expect state 'session.header.icon=>_'
    Invoke-Aio expect state 'session.header.directory=C:\Header Test'
    Invoke-Aio expect state session.header.directory_source=shell
    Header-Button 1
    Invoke-Aio wait text 'Microsoft Windows'
    Invoke-Aio expect state 'session.header.icon=C:'
    Invoke-Aio expect state 'session.header.directory=C:\Windows'
    Invoke-Aio expect state session.header.directory_source=launch
    Invoke-Aio expect state panes.count=3
    Header-Button 3
    Invoke-Aio expect state panes.count=2
    Invoke-Aio expect state "session.id=$session"
    Set-Option shell.command 'pwsh.exe -NoLogo'
    Invoke-Aio command settings.reload
    Header-Button 2
    Invoke-Aio expect state panes.count=1
    Invoke-Aio expect state panes.header_height=28
    Invoke-Aio expect state "session.id=$session"
    Shot zoomed
    Header-Button 2
    Invoke-Aio expect state panes.count=2
    Header-Button 0
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state panes.count=3
    $thirdNode = (Read-State)['panes.focused']
    Header-Button 1
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state panes.count=4
    $s = Read-State
    $other = "pane.$thirdNode.rect"
    $r = $s[$other] -split ',' | ForEach-Object { [double]$_ }
    Invoke-Aio mouse click "$([int]($r[0]+35)),$([int]($r[1]+14))" --px
    Invoke-Aio expect state "panes.focused=$(($other -split '\.')[1])"
    $fixture = Join-Path $PSScriptRoot 'header_mouse_fixture.ps1'
    Invoke-Aio run ('function prompt { "H> " }; Clear-Host; & "' + $fixture + '"')
    Invoke-Aio wait text MS_READY
    Invoke-Aio expect state session.mouse=true
    $s = Read-State
    $r = $s["pane.$($s['panes.focused']).rect"] -split ',' | ForEach-Object { [double]$_ }
    $hx = [int]($r[0]+$r[2]-16)
    $hy = [int]($r[1]+14)
    $bodyY = [int]($r[1]+75)
    foreach ($button in @('left','right','middle')) {
        Invoke-Aio mouse down "$hx,$hy" --button $button --px
        Invoke-Aio mouse move "$hx,$bodyY" --px
        Invoke-Aio mouse up "$hx,$bodyY" --button $button --px
    }
    Invoke-Aio mouse down "$hx,$hy" --px
    Invoke-Aio mouse up '10,15' --px
    Invoke-Aio mouse down "$hx,$hy" --px
    Invoke-Aio key Ctrl+Shift+P
    Invoke-Aio mouse up '10,15' --px
    Invoke-Aio key Esc
    Invoke-Aio mouse down "$hx,$hy" --px
    Invoke-Aio command settings.reload
    Invoke-Aio mouse up "$hx,$bodyY" --px
    Invoke-Aio mouse down "$hx,$hy" --px
    Invoke-Aio command terminal.find
    Invoke-Aio mouse up '100,15' --px
    Invoke-Aio key Esc
    Invoke-Aio mouse wheel "$hx,$hy" 2 --px
    Invoke-Aio type q
    Invoke-Aio wait text MOUSE_BYTES=none
    # A real terminal click must reach the same reader; otherwise the negative proof is vacuous.
    Invoke-Aio run ('Clear-Host; & "' + $fixture + '"')
    Invoke-Aio wait text MS_READY
    Invoke-Aio mouse click "$hx,$bodyY" --px
    Invoke-Aio type q
    Invoke-Aio wait text MOUSE_BYTES=1B5B3C
    Invoke-Aio expect no-text MOUSE_BYTES=none
    $savedClipboard = Get-Clipboard -Raw
    try {
        Invoke-Aio run 'Clear-Host; Write-Output ("SELECT_"+"HEADER")'
        Invoke-Aio wait text SELECT_HEADER
        Invoke-Aio mouse drag '0,0' '13,0'
        if ((Read-State)['session.selection'] -notlike '*SELECT_HEADER*') { throw 'Selection origin includes the header.' }
        Invoke-Aio key Esc
        Invoke-Aio key Ctrl+Shift+F
        Invoke-Aio type SELECT_HEADER
        Invoke-Aio expect state 'find.matches=1 match'
        Invoke-Aio key Esc
    } finally { Set-Clipboard -Value $savedClipboard }
    Invoke-Aio run '[Console]::Write([char]27 + "c"); Start-Sleep -Milliseconds 500'
    Invoke-Aio wait idle 800
    Invoke-Aio expect state session.header.title=pwsh
    Invoke-Aio expect state 'session.header.directory=C:\Windows'
    $fullSize = (Read-State)['window.size']
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Resize 400x300
    Shot narrow
    Invoke-Aio expect state panes.count=4
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Resize $fullSize
    foreach ($theme in @(@('studio','dark'), @('studio','light'), @('tide','dark'))) {
        Set-Option theme.name $theme[0]
        Set-Option theme.mode $theme[1]
        Invoke-Aio command settings.reload
        Shot "$($theme[0])-$($theme[1])-four"
    }
    foreach ($dpi in @(96,144,168)) {
        Invoke-Aio dpi $dpi
        foreach ($gap in @(0,5,24)) {
            foreach ($radius in @(0,7)) {
                Set-Option pane.gap "$gap"
                Set-Option pane.corner_radius "$radius"
                Invoke-Aio command settings.reload
                Assert-Equal ([double](Read-State)['panes.header_height']) (28*$dpi/96) 'scaled header height'
                Assert-Origin
                Shot "geometry-$dpi-$gap-$radius"
            }
        }
        $savedClipboard = Get-Clipboard -Raw
        try {
            Invoke-Aio run 'Clear-Host; Write-Output ("SCALE_"+"OK")'
            Invoke-Aio wait text SCALE_OK
            Invoke-Aio mouse drag '0,0' '8,0'
            if ((Read-State)['session.selection'] -notlike '*SCALE_OK*') { throw 'Scaled selection used the header origin.' }
            Invoke-Aio key Esc
            Invoke-Aio command terminal.find
            Invoke-Aio type SCALE_OK
            Invoke-Aio expect state 'find.matches=1 match'
            Invoke-Aio key Esc
        } finally { Set-Clipboard -Value $savedClipboard }
        Invoke-Aio run ('Clear-Host; & "' + $fixture + '"')
        Invoke-Aio wait text MS_READY
        Invoke-Aio mouse click '0,0'
        Invoke-Aio type q
        Invoke-Aio wait text 'XY=1,1'
        $s = Read-State
        $node = $s['panes.focused']
        $rectBefore = $s["pane.$node.rect"]
        $r = $rectBefore -split ',' | ForEach-Object { [double]$_ }
        $dx = [int]($r[0]+$r[2]/2)
        $dy = [int]($r[1]+$r[3]+[double]$s['panes.gap']/2)
        Invoke-Aio mouse drag "$dx,$dy" "$dx,$($dy+[int](10*$dpi/96))" --px
        if ((Read-State)["pane.$node.rect"] -eq $rectBefore) { throw 'Scaled divider drag did not change geometry.' }
        Invoke-Aio command pane.balance
        Assert-Origin
    }
    Invoke-Aio dpi 96
    Set-Option pane.show_headers false
    Invoke-Aio command settings.reload
    Invoke-Aio expect state panes.header_height=0
    Assert-Origin
    Shot hidden
    Start-Sleep -Milliseconds 6600
    Assert-Idle
    Set-Option pane.show_headers true
    Set-Option shell.icon 'λ'
    Invoke-Aio command settings.reload
    Invoke-Aio expect state 'session.header.icon=λ'
    Shot custom-icon
    Start-Sleep -Milliseconds 6600
    $s = Read-State
    $r = $s["pane.$($s['panes.focused']).rect"] -split ',' | ForEach-Object { [double]$_ }
    $x = [int]($r[0]+$r[2]-16)
    $y = [int]($r[1]+14)
    Invoke-Aio mouse move "$x,$y" --px
    Assert-Idle
    Invoke-Aio mouse move "$($x+1),$y" --px
    Assert-Idle
    Invoke-Aio mouse down "$x,$y" --px
    Invoke-Aio mouse up "$x,$([int]($r[1]+50))" --px
    Invoke-Aio expect state panes.count=4
    Assert-Idle
    [AioHeaderAnimations]::Write($true)
    Invoke-Aio command settings.reload
    Invoke-Aio expect state ui.animations=true
    Start-Sleep -Milliseconds 6600
    Invoke-Aio mouse move "$x,$y" --px
    Assert-Idle
    Invoke-Aio mouse move "$($x+1),$y" --px
    Assert-Idle
    Shot animated-hover
    Write-Output 'PASS headers, metadata, actions, geometry, themes, hide/reload and idle'
} finally {
    & $ctl --name $name stop | Write-Output
    [AioHeaderAnimations]::Write($originalAnimations)
}
