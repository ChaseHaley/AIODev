[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9_-]{1,20}$')]
    [string] $Label,
    [ValidateRange(1, 10)]
    [int] $Runs = 3,
    [string] $Benchmark = 'C:\Users\chale\Libraries\termbench\termbench_release_msvc.exe',
    [string] $Executable,
    [string] $ProcessGroups = '',
    [ValidateSet('dark', 'light')]
    [string] $ThemeMode = 'dark',
    [double] $MinimumContrast = 4.5,
    [switch] $HideHeaders,
    [ValidateRange(1, 120)]
    [int] $StartupSeconds = 15,
    [ValidateRange(1, 300)]
    [int] $AdmissionSeconds = 30,
    [ValidateRange(1, 3600)]
    [int] $CompletionSeconds = 0,
    [string] $Token,
    [switch] $Child
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$data = Join-Path $repo "build/termbench/$Label"
. (Join-Path $PSScriptRoot 'termbench_common.ps1')

if ($Child) {
    try {
        if ($Token -notmatch '^[a-f0-9]{32}$') { throw 'Missing cohort token.' }
        Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class TermBenchScreen {
    [StructLayout(LayoutKind.Sequential)]
    public struct Coord { public short X, Y; }
    [DllImport("kernel32.dll")]
    static extern IntPtr GetStdHandle(int id);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool ReadConsoleOutputCharacter(IntPtr h, StringBuilder text, uint size, Coord at, out uint read);
    public static string Read() {
        var text = new StringBuilder(20000);
        uint read;
        if (!ReadConsoleOutputCharacter(GetStdHandle(-11), text, 20000, new Coord(), out read))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return text.ToString();
    }
}
'@
        Write-TermBenchSignal (Join-Path $data 'ready.txt') $Token
        $wait = [Diagnostics.Stopwatch]::StartNew()
        $start = Join-Path $data 'start.txt'
        while (-not (Test-Path -LiteralPath $start)) {
            if ($wait.Elapsed.TotalSeconds -ge ($StartupSeconds + $AdmissionSeconds + 10)) {
                throw 'Child admission handshake timed out; benchmark not started.'
            }
            Start-Sleep -Milliseconds 100
        }
        if ([IO.File]::ReadAllText($start) -ne $Token) { throw 'Invalid start token.' }
        for ($i = 1; $i -le $Runs; $i++) {
            & $Benchmark normal
            if ($LASTEXITCODE -ne 0) { throw "TermBench failed: $LASTEXITCODE" }
            [IO.File]::WriteAllText((Join-Path $data "run-$i.txt"), [TermBenchScreen]::Read())
        }
        Write-TermBenchSignal (Join-Path $data 'done.txt') $Token
        # Keep the shell/window alive until the parent observes completion and closes its job.
        Start-Sleep -Seconds 30
        throw 'Parent did not collect completion within 30 seconds.'
    } catch {
        Write-TermBenchSignal (Join-Path $data 'child-failure.txt') $_.Exception.Message
        throw
    }
}

$Benchmark = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Benchmark)
if (-not (Test-Path -LiteralPath $Benchmark)) { throw "Missing TermBench: $Benchmark" }
if (Test-Path -LiteralPath $data) { throw "Choose an unused benchmark label: $data already exists." }
New-Item -ItemType Directory -Path $data -Force | Out-Null
$Token = [Guid]::NewGuid().ToString('N')
if ($CompletionSeconds -eq 0) { $CompletionSeconds = 300 * $Runs }
$shellExecutable = (Get-Process -Id $PID).Path
$shell = '"' + $shellExecutable + '" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' +
    $PSCommandPath + '" -Label ' + $Label + ' -Runs ' + $Runs + ' -Benchmark "' + $Benchmark +
    '" -Token ' + $Token + ' -StartupSeconds ' + $StartupSeconds +
    ' -AdmissionSeconds ' + $AdmissionSeconds + ' -Child'
$settings = @(
    "shell.command = $shell"
    "shell.directory = $repo"
    'window.columns = 120'
    'window.rows = 32'
    'font.family = Cascadia Mono'
    'font.size = 12'
    'cursor.blink = false'
    "process.padding_groups = $ProcessGroups"
    "theme.mode = $ThemeMode"
)
if ($HideHeaders) { $settings += 'pane.show_headers = false' }
if ($MinimumContrast -ne 4.5) { $settings += "terminal.minimum_contrast = $MinimumContrast" }
[IO.File]::WriteAllLines((Join-Path $data 'settings.ini'), $settings)
if ($Executable -eq '') { $Executable = Join-Path $repo 'build/release/aiodev.exe' }
$Executable = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Executable)
$arguments = '--no-activate --instance bench-' + $Label + ' --data-dir "' + $data + '"'
$clock = [Diagnostics.Stopwatch]::StartNew()
$actions = @{
    Now = { $clock.Elapsed.TotalSeconds }
    Sleep = { Start-Sleep -Milliseconds 300 }
    Launch = {
        if (-not ('TermBenchProcess' -as [type])) {
            Add-Type -Path (Join-Path $PSScriptRoot 'termbench_windows.cs')
        }
        [TermBenchProcess]::Launch($Executable, $arguments, $repo)
    }
    State = { param($owner) Read-TermBenchState $owner $data $Token }
    Probe = { param($owner) [TermBenchDisplay]::Probe($owner.Id) }
    Start = { param($owner) Write-TermBenchSignal (Join-Path $data 'start.txt') $Token }
    Summaries = { Read-TermBenchSummaries $data $Runs }
    Cleanup = { param($owner) $owner.Dispose() }
    Event = {
        param($phase, $probe)
        $entry = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); phase = $phase
            valid = $probe.Valid; detail = $probe.Detail }
        [IO.File]::AppendAllText((Join-Path $data 'conditions.jsonl'), ($entry | ConvertTo-Json -Compress) + "`n")
    }
    Receipt = {
        param($status, $phase, $failure, $started)
        $receipt = [ordered]@{ status = $status; phase = $phase; failure = $failure; started = $started
            utc = [DateTime]::UtcNow.ToString('o'); token = $Token; executable = $Executable
            processId = $(if ($null -ne $owner) { $owner.Id } else { 0 })
            arguments = $arguments; benchmark = $Benchmark; runs = $Runs; shell = $shellExecutable
            startupSeconds = $StartupSeconds; admissionSeconds = $AdmissionSeconds
            completionSeconds = $CompletionSeconds; sampleIntervalMs = 300 }
        [IO.File]::WriteAllText((Join-Path $data 'receipt.json'), ($receipt | ConvertTo-Json))
    }
}
Invoke-TermBenchCohort $actions $StartupSeconds $AdmissionSeconds $CompletionSeconds
