[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'visual-motion'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AioAnimations {
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
function Assert-Idle {
    Start-Sleep -Milliseconds 250
    $frames = (Read-State)['frames.presented']
    Start-Sleep -Milliseconds 450
    if ((Read-State)['frames.presented'] -ne $frames) { throw 'Idle window drew extra frames.' }
    Write-Output 'PASS idle window draws no extra frames'
    Invoke-Aio expect state ui.animating=false
}
$original = [AioAnimations]::Read()
try {
    [AioAnimations]::Write($false)
    Invoke-Aio launch --fresh
    Invoke-Aio expect state ui.animations=false
    Invoke-Aio key Ctrl+Shift+P
    Invoke-Aio expect state ui.animating=false
    Assert-Idle
    Invoke-Aio key Esc
    Invoke-Aio run 'Write-Output ("IMMEDIATE_" + "INPUT")'
    Invoke-Aio expect text IMMEDIATE_INPUT
    Assert-Idle
    [AioAnimations]::Write($true)
    [AioAnimations]::Notify([int](Get-Content (Join-Path $repo "build/verify/$name/instance.ini") | Where-Object { $_ -like 'pid=*' }).Substring(4))
    Invoke-Aio expect state ui.animations=true
    Invoke-Aio key Ctrl+Shift+P
    Invoke-Aio key Esc
    Invoke-Aio run 'Write-Output ("ANIMATION_" + "OUTPUT")'
    Invoke-Aio expect text ANIMATION_OUTPUT
    Assert-Idle
    Invoke-Aio command settings.reload
    Start-Sleep -Milliseconds 6700
    Assert-Idle
    Invoke-Aio key 'Ctrl+,'
    Invoke-Aio mouse move '40,40' --px
    Assert-Idle
    Invoke-Aio mouse move '41,41' --px
    Assert-Idle
    Invoke-Aio key Esc
    [AioAnimations]::Write($false)
    [AioAnimations]::Notify([int](Get-Content (Join-Path $repo "build/verify/$name/instance.ini") | Where-Object { $_ -like 'pid=*' }).Substring(4))
    Invoke-Aio expect state ui.animations=false
    Invoke-Aio key Ctrl+Shift+T
    Invoke-Aio expect state ui.animating=false
    Assert-Idle
    Write-Output 'PASS startup and live animation preference, palette, tabs, notices, settings and immediate input'
} finally {
    & $ctl --name $name stop | Write-Output
    [AioAnimations]::Write($original)
}

