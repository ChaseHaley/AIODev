[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source = [IO.File]::ReadAllText((Join-Path $repo 'tools/win32.ps1'))
$methods = [regex]::Match($source, '(?s)    static string WindowIdentity\(.*?(?=    static INPUT Key\()').Value
if (-not $methods) { throw 'Cannot locate the actual helper activation methods.' }

# Compile the actual activation methods against deterministic native-call substitutes; no Windows API runs.
$stub = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ActivationTest {
    public static Queue<IntPtr> Foregrounds;
    public static bool Accepted, Responsive;
    public static int SetCalls, WaitCalls;
    public static void Reset(bool accepted, bool responsive, long[] foregrounds) {
        Accepted = accepted; Responsive = responsive; SetCalls = WaitCalls = 0;
        Foregrounds = new Queue<IntPtr>();
        foreach (long h in foregrounds) Foregrounds.Enqueue(new IntPtr(h));
    }
    static IntPtr GetForegroundWindow() { return Foregrounds.Dequeue(); }
    static bool SetForegroundWindow(IntPtr h) { ++SetCalls; return Accepted; }
    static uint GetWindowThreadProcessId(IntPtr h, out uint pid) { pid = (uint)h.ToInt64(); return pid; }
    static uint GetCurrentProcessId() { return 99; }
    static void SetLastError(uint code) { }
    static IntPtr SendMessageTimeoutW(IntPtr h, uint message, UIntPtr w, IntPtr l,
        uint flags, uint timeout, out UIntPtr result) {
        ++WaitCalls;
        if (h != new IntPtr(42) || message != 0 || w != UIntPtr.Zero || l != IntPtr.Zero ||
            flags != 0x22 || timeout != 2000) throw new Exception("unexpected synchronization arguments");
        result = UIntPtr.Zero;
        return Responsive ? new IntPtr(1) : IntPtr.Zero;
    }
'@
Add-Type -TypeDefinition ($stub + "`n" + $methods + "`n}")

function Assert-Case([string] $Label, [bool] $Accepted, [bool] $Responsive,
    [long[]] $Foregrounds, [int] $Waits, [string] $Failure, [string] $Completion) {
    [ActivationTest]::Reset($Accepted, $Responsive, $Foregrounds)
    $message = ''
    $trace = ''
    try { $trace = [ActivationTest]::Activate([IntPtr]42) }
    catch { $message = $_.Exception.GetBaseException().Message }
    if ($Failure) {
        if (-not $message.StartsWith($Failure)) { throw "$Label expected '$Failure', observed '$message'" }
        $trace = $message
    } elseif ($message) { throw "$Label unexpectedly failed: $message" }
    if ([ActivationTest]::SetCalls -ne 1 -or [ActivationTest]::WaitCalls -ne $Waits -or
        [ActivationTest]::Foregrounds.Count -ne 0) { throw "$Label unexpected native-call sequence" }
    foreach ($field in @("SetForegroundWindow=$Accepted", 'callerPid=99', 'target=42/pid=42/tid=42',
        "completion=$Completion", 'before=', 'immediate=', 'final=', 'completionError=', 'elapsedMs=')) {
        if (-not $trace.Contains($field)) { throw "$Label missing diagnostic $field : $trace" }
    }
    Write-Output "PASS $Label (deterministic native substitutes): $trace"
}

Assert-Case 'refusal never synchronizes' $false $true @(7,7) 0 'activation request refused;' 'not-needed'
Assert-Case 'false BOOL still refuses an already foreground target' $false $true @(42,42) 0 'activation request refused;' 'not-needed'
Assert-Case 'immediate success needs no synchronization' $true $true @(7,42) 0 '' 'not-needed'
Assert-Case 'accepted asynchronous activation completes' $true $true @(7,7,42) 1 '' 'processed'
Assert-Case 'unresponsive completion fails even if foreground changed' $true $false @(7,7,42) 1 'activation completion check failed;' 'failed'
Assert-Case 'foreground interference still fails after responsive completion' $true $true @(7,7,8) 1 'target did not retain foreground;' 'processed'
