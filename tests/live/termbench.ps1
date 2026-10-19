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
    [switch] $Child
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$data = Join-Path $repo "build/termbench/$Label"

if ($Child) {
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
    for ($i = 1; $i -le $Runs; $i++) {
        & $Benchmark normal
        if ($LASTEXITCODE -ne 0) { throw "TermBench failed: $LASTEXITCODE" }
        [IO.File]::WriteAllText((Join-Path $data "run-$i.txt"), [TermBenchScreen]::Read())
    }
    [IO.File]::WriteAllText((Join-Path $data 'done.txt'), 'done')
    exit 0
}

if (-not (Test-Path -LiteralPath $Benchmark)) { throw "Missing TermBench: $Benchmark" }
if (Test-Path -LiteralPath $data) { throw "Choose an unused benchmark label: $data already exists." }
New-Item -ItemType Directory -Path $data -Force | Out-Null
$shell = 'pwsh.exe -NoLogo -NoProfile -File "' + $PSCommandPath + '" -Label ' + $Label +
    ' -Runs ' + $Runs + ' -Benchmark "' + $Benchmark + '" -Child'
$settings = @(
    "shell.command = $shell"
    "shell.directory = $repo"
    'window.columns = 120'
    'window.rows = 32'
    'font.family = Cascadia Mono'
    'font.size = 12'
    'cursor.blink = false'
    "process.padding_groups = $ProcessGroups"
)
[IO.File]::WriteAllLines((Join-Path $data 'settings.ini'), $settings)
if ($Executable -eq '') { $Executable = Join-Path $repo 'build/release/aiodev.exe' }
$arguments = '--instance bench-' + $Label + ' --data-dir "' + $data + '"'
$process = Start-Process -FilePath $Executable -ArgumentList $arguments -WindowStyle Hidden -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddMinutes(5 * $Runs)
    while (-not (Test-Path -LiteralPath (Join-Path $data 'done.txt'))) {
        if ($process.HasExited) { throw 'AIODev exited before the benchmark finished.' }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'TermBench timed out.' }
        Start-Sleep -Milliseconds 300
    }
    foreach ($i in 1..$Runs) {
        $screen = [IO.File]::ReadAllText((Join-Path $data "run-$i.txt"))
        $results = [regex]::Matches($screen,
            '(ManyLine|LongLine|FGPerChar|FGBGPerChar|TermMarkV2 Normal): [0-9.]+s \([0-9.]+gb/s\)')
        if ($results.Count -ne 5) { throw "Missing summary in run $i." }
        Write-Output "Run $i"
        $results | ForEach-Object Value | Write-Output
    }
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id }
    $process.Dispose()
}
