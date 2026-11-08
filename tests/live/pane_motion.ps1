[CmdletBinding()]
param(
    # Each split and close is repeated this many times per gap setting.
    [ValidateRange(1, 100)]
    [int] $Rounds = 5
)
# Splits and closes panes and proves from the swap chain's own statistics that every motion frame met
# its vblank: no repeated vblanks, and every animated frame reached the screen the same time after the
# instant it was built for. Runs with pane gaps and without, and with Windows animations off.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'pane-motion'
$captures = Join-Path $repo 'build/verify/pane-motion-captures'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AioPaneAnimations {
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
function Read-Pairs([string[]] $Lines) {
    $values = @{}
    foreach ($line in $Lines) { $pair = $line -split '=', 2; $values[$pair[0]] = $pair[1] }
    return $values
}
function Read-State { Read-Pairs (Invoke-Aio state) }
function Read-Perf([switch] $Reset) {
    if ($Reset) { return Read-Pairs (Invoke-Aio perf --reset) }
    Read-Pairs (Invoke-Aio perf)
}
function Wait-Settled {
    for ($i = 0; $i -lt 100; $i++) {
        if ((Read-State)['ui.animating'] -eq 'false') { return }
        Start-Sleep -Milliseconds 20
    }
    throw 'Motion did not settle.'
}
function Notify-Animations {
    $instance = Get-Content (Join-Path $repo "build/verify/$name/instance.ini")
    [AioPaneAnimations]::Notify([int]($instance | Where-Object { $_ -like 'pid=*' }).Substring(4))
}
# One split or close: the panes move, every frame met its vblank, and they land on the layout. A drive
# replies once nothing moves, so the motion is over when the command returns.
function Assert-Motion([string] $Label, [string[]] $Command) {
    $null = Read-Perf -Reset
    Invoke-Aio command @Command | Out-Null
    Wait-Settled
    $perf = Read-Perf
    $settled = Read-State
    $period = [double]$perf['display.period.us']
    $frames = [int]$perf['motion.frames']
    $repeated = [int]$perf['motion.repeated']
    $skipped = [int]$perf['motion.display_skipped']
    $spread = [double]$perf['motion.offset.max.us'] - [double]$perf['motion.offset.min.us']
    # 160 ms at the display's refresh, less one frame for the start that waits out a resuming frame.
    $expected = [math]::Floor(160000 / $period) - 1
    if ($frames -lt $expected) { throw "$Label drew $frames motion frames; expected at least $expected." }
    if ($repeated -ne 0) { throw "$Label repeated $repeated vblanks." }
    if ($skipped -ne 0) { throw "$Label left $skipped vblanks of its display without a frame built for them." }
    if ($spread -gt [math]::Max(250, $period * 0.05)) { throw "$Label frames landed $spread us apart." }
    foreach ($key in $settled.Keys | Where-Object { $_ -like 'pane.*.rect' }) {
        $shown = $key -replace '\.rect$', '.shown'
        if ($settled[$shown] -ne $settled[$key]) { throw "$Label left $shown at $($settled[$shown]), not $($settled[$key])." }
    }
    Write-Output ("PASS {0}: {1} frames for a {2:N1} Hz display, 0 repeated or skipped vblanks, landing spread {3:N0} us" -f `
        $Label, $frames, (1e6 / $period), $spread)
}
# A moment after a window appears or moves, the compositor switches how it presents it (composed or
# flipped directly), which moves when frames reach the screen by a refresh. That is the compositor's
# doing; one split and close let it settle before anything is measured.
function Warm-Up {
    Invoke-Aio command pane.split_right | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio command pane.close | Out-Null
    Start-Sleep -Milliseconds 1500
}
function Run-Rounds([string] $Gap) {
    for ($round = 1; $round -le $Rounds; $round++) {
        Assert-Motion "gap $Gap split right $round" @('pane.split_right')
        Invoke-Aio wait text 'PS ' | Out-Null
        Assert-Motion "gap $Gap split down $round" @('pane.split', '--direction', 'down')
        Invoke-Aio wait text 'PS ' | Out-Null
        Assert-Motion "gap $Gap close $round" @('pane.close')
        Assert-Motion "gap $Gap close $round again" @('pane.close')
        Invoke-Aio expect state panes.count=1 | Out-Null
    }
}
$original = [AioPaneAnimations]::Read()
$settings = Join-Path ([IO.Path]::GetTempPath()) "aio-pane-motion-$PID.ini"
try {
    New-Item -ItemType Directory -Force $captures | Out-Null
    [AioPaneAnimations]::Write($true)
    Invoke-Aio launch --fresh | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Wait-Settled
    Warm-Up
    Run-Rounds 4

    # A float is another container: its panes move inside it just as tiled panes do in the window.
    Invoke-Aio command pane.new_floating | Out-Null
    Invoke-Aio expect state panes.floating=1 | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Wait-Settled
    Assert-Motion 'float split right' @('pane.split_right')
    Invoke-Aio wait text 'PS ' | Out-Null
    Assert-Motion 'float split down' @('pane.split', '--direction', 'down')
    Invoke-Aio wait text 'PS ' | Out-Null
    Assert-Motion 'float close' @('pane.close')
    Assert-Motion 'float close again' @('pane.close')
    Invoke-Aio expect state panes.floating=1 | Out-Null
    Assert-Motion 'float minimize' @('pane.minimize_floating')
    Invoke-Aio expect state panes.capsules=1 | Out-Null
    Assert-Motion 'float restore' @('pane.minimize_floating')
    Invoke-Aio expect state panes.capsules=0 | Out-Null
    Invoke-Aio command pane.close | Out-Null
    Invoke-Aio expect state panes.floating=0 | Out-Null
    Wait-Settled

    # Every other change that sets a pane's size at once eases it there too; only the user's own drags
    # and the OS maximizing the window do not.
    Invoke-Aio command pane.split_right | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Wait-Settled
    Assert-Motion 'swap' @('pane.swap_left')
    Assert-Motion 'resize from the keyboard' @('pane.resize_right_large')
    Assert-Motion 'balance' @('pane.balance')
    Assert-Motion 'zoom' @('pane.zoom')
    Assert-Motion 'leave zoom' @('pane.zoom')
    Assert-Motion 'fill window' @('pane.fill_window')
    Assert-Motion 'leave fill window' @('pane.fill_window')
    Assert-Motion 'hide the Activity panel' @('status.panel')
    Assert-Motion 'show the Activity panel' @('status.panel')
    Assert-Motion 'close after the rest' @('pane.close')

    # Every other display, which may refresh at another rate than the compositor's clock.
    Add-Type -AssemblyName System.Windows.Forms
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary }) {
        $b = $screen.Bounds
        Invoke-Aio window move "$($b.X + 100),$($b.Y + 100)" | Out-Null
        Warm-Up
        Assert-Motion "$($screen.DeviceName) split right" @('pane.split_right')
        Invoke-Aio wait text 'PS ' | Out-Null
        Assert-Motion "$($screen.DeviceName) close" @('pane.close')
    }
    Invoke-Aio window move '100,100' | Out-Null
    Start-Sleep -Milliseconds 1000

    # The settled layout, for the visual record.
    Invoke-Aio command pane.split_right | Out-Null
    Wait-Settled
    Invoke-Aio capture --out (Join-Path $captures 'split-settled.png') | Out-Null
    Invoke-Aio command pane.close | Out-Null
    Wait-Settled
    Invoke-Aio stop | Out-Null

    # Without gaps, neighbours share one border while they move.
    Set-Content -LiteralPath $settings -Value "pane.gap = 0`n"
    Invoke-Aio launch --fresh --settings $settings | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio expect state panes.gap=1 | Out-Null
    Wait-Settled
    Warm-Up
    Run-Rounds 0
    Invoke-Aio command pane.split_right | Out-Null
    Wait-Settled
    Invoke-Aio capture --out (Join-Path $captures 'split-settled-gap0.png') | Out-Null
    Invoke-Aio command pane.close | Out-Null
    Wait-Settled

    # With Windows animations off, the layout shows at once.
    [AioPaneAnimations]::Write($false)
    Notify-Animations
    Invoke-Aio expect state ui.animations=false | Out-Null
    $null = Read-Perf -Reset
    Invoke-Aio command pane.split_right | Out-Null
    Invoke-Aio expect state ui.animating=false | Out-Null
    if ((Read-Perf)['motion.frames'] -ne '0') { throw 'A split with animations off moved the panes.' }
    Write-Output 'PASS split with animations off lands at once'
    Write-Output "PASS pane split and close motion; captures in $captures"
} finally {
    & $ctl --name $name stop | Out-Null
    [AioPaneAnimations]::Write($original)
    Remove-Item -LiteralPath $settings -ErrorAction SilentlyContinue
}
