<#
.SYNOPSIS
Builds two versions of AIODev and opens them side by side with the same settings.

.DESCRIPTION
Each side is a git ref (branch, tag or commit) or the path of a checkout or worktree. A ref is checked
out into a cached worktree under build/compare; a path is built in place, uncommitted changes
included. Both sides are release builds in their own folders and run as separate instances with
their own data folders, so they never share a window, a control pipe, settings or saved layout.
Base opens on the left half of the monitor and Candidate on the right, each at the same size.
-CandidateOnly skips Base and opens Candidate across the whole monitor.

Settings: by default both start from defaults with no saved layout. -Settings copies one file into
both; -MySettings copies your own settings.ini. Either way both sides read identical settings, so any
difference you see comes from the code.

.EXAMPLE
.\tools\compare.ps1 -Candidate build\work285-design-system
Main on the left, the design-system worktree on the right.

.EXAMPLE
.\tools\compare.ps1 -Base v0.4.0 -Candidate main -MySettings
The last release against main, both with your settings.

.EXAMPLE
.\tools\compare.ps1 -CandidateOnly -MySettings
Only the current checkout, with your settings.

.EXAMPLE
.\tools\compare.ps1 -Stop
Closes the compare windows.
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')]
    [string] $Base = 'main',

    [Parameter(ParameterSetName = 'Run')]
    [string] $Candidate = '.',

    [Parameter(ParameterSetName = 'Run')]
    [string] $Settings,

    [Parameter(ParameterSetName = 'Run')]
    [switch] $MySettings,

    # Keep each side's data folder (settings edits, layout) from the previous compare.
    [Parameter(ParameterSetName = 'Run')]
    [switch] $KeepData,

    # Reuse the previous builds instead of building again.
    [Parameter(ParameterSetName = 'Run')]
    [switch] $NoBuild,

    # Build and open only the candidate, filling the monitor.
    [Parameter(ParameterSetName = 'Run')]
    [switch] $CandidateOnly,

    # Zero-based monitor index in the order Windows lists screens; the primary monitor by default.
    [Parameter(ParameterSetName = 'Run')]
    [int] $Monitor = -1,

    [Parameter(ParameterSetName = 'Stop', Mandatory)]
    [switch] $Stop
)

$ErrorActionPreference = 'Stop'
$here = (Get-Location).Path

# The compare folder lives in the main checkout so every worktree shares one cache and one pair.
$common = (& git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir).Trim()
if ($LASTEXITCODE -ne 0) { throw 'compare.ps1 must run from inside an AIODev checkout.' }
$repo = Split-Path $common -Parent
$root = Join-Path $repo 'build/compare'
$record = Join-Path $root 'running.json'
New-Item -ItemType Directory -Force $root | Out-Null

Add-Type -AssemblyName System.Windows.Forms
if (-not ('AIODevCompare.Win32' -as [type])) {
    Add-Type -Namespace AIODevCompare -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr param);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out RECT value, int size);
// Places the visible frame, not the window rectangle, at the given bounds: Windows 11 windows carry
// invisible resize borders that would otherwise leave gaps between neighbours.
public static void PlaceFrame(IntPtr hWnd, int x, int y, int width, int height) {
    SetWindowPos(hWnd, IntPtr.Zero, x, y, width, height, 0x0014);
    RECT window, frame;
    if (!GetWindowRect(hWnd, out window) || DwmGetWindowAttribute(hWnd, 9, out frame, 16) != 0) return;
    int left = frame.Left - window.Left, top = frame.Top - window.Top;
    int right = window.Right - frame.Right, bottom = window.Bottom - frame.Bottom;
    SetWindowPos(hWnd, IntPtr.Zero, x - left, y - top, width + left + right, height + top + bottom, 0x0014);
}
public delegate bool EnumProc(IntPtr hWnd, IntPtr param);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
public static IntPtr LargestWindow(uint pid) {
    IntPtr best = IntPtr.Zero; long area = 0;
    EnumWindows((h, p) => {
        uint owner; GetWindowThreadProcessId(h, out owner);
        RECT r;
        if (owner == pid && IsWindowVisible(h) && GetWindow(h, 4) == IntPtr.Zero && GetWindowRect(h, out r)) {
            long a = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
            if (a > area) { area = a; best = h; }
        }
        return true;
    }, IntPtr.Zero);
    return best;
}
'@
}

# Per-monitor awareness makes screen areas and window positions physical pixels, as the app uses.
[AIODevCompare.Win32]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null

function Stop-Compare {
    if (-not (Test-Path $record)) { return }
    foreach ($side in (Get-Content $record -Raw | ConvertFrom-Json)) {
        $process = Get-Process -Id $side.pid -ErrorAction SilentlyContinue
        # Closing the window only hides AIODev to the tray, so end the throwaway instance and its
        # shells outright. The path check keeps a reused process ID from hitting another program.
        if ($process -and $process.Path -eq $side.exe) {
            # A child may already be exiting; taskkill reports that on stderr, which is not a failure.
            & cmd.exe /d /c "taskkill /PID $($side.pid) /T /F >nul 2>&1"
            $process.WaitForExit(5000) | Out-Null
        }
    }
    Remove-Item $record -Force
}

# A side is a checkout path when one exists there; otherwise a ref checked out into the cache.
function Resolve-Side([string] $Spec, [string] $Name) {
    $path = if ([IO.Path]::IsPathRooted($Spec)) { $Spec } else { Join-Path $here $Spec }
    if ((Test-Path (Join-Path $path 'build.ps1')) -and (Test-Path (Join-Path $path 'src'))) {
        $source = (Resolve-Path $path).Path
        $branch = (& git -C $source rev-parse --abbrev-ref HEAD).Trim()
        $commit = (& git -C $source rev-parse --short HEAD).Trim()
        $dirty = if (& git -C $source status --porcelain) { '+dirty' } else { '' }
        return [pscustomobject]@{ Name = $Name; Source = $source; Label = "$branch@$commit$dirty"; Cached = $false }
    }
    $commit = (& git -C $repo rev-parse --verify --quiet "$Spec^{commit}")
    if ($LASTEXITCODE -ne 0 -or -not $commit) { throw "$Name '$Spec' is neither a checkout folder nor a git ref." }
    $commit = $commit.Trim()
    $source = Join-Path $root "src-$($Name.ToLower())"
    if (-not (Test-Path (Join-Path $source '.git'))) {
        & git -C $repo worktree add --detach $source $commit 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Cannot create a worktree for $Spec at $source." }
    } elseif ((& git -C $source rev-parse HEAD).Trim() -ne $commit) {
        # The cache is ours alone, so a forced checkout loses nothing.
        & git -C $source checkout --detach --force $commit 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Cannot check out $Spec in $source." }
    }
    $short = (& git -C $repo rev-parse --short $commit).Trim()
    return [pscustomobject]@{ Name = $Name; Source = $source; Label = "$Spec@$short"; Cached = $true }
}

function Build-Side($Side) {
    $exe = Join-Path $root "$($Side.Name.ToLower())/aiodev.exe"
    $stamp = "$exe.source"
    $current = "$($Side.Source)|$($Side.Label)"
    # A cached ref that already built at this commit needs no rebuild; a working checkout always does.
    $fresh = $Side.Cached -and (Test-Path $exe) -and (Test-Path $stamp) -and (Get-Content $stamp -Raw).Trim() -eq $current
    if (-not $NoBuild -and -not $fresh) {
        Write-Host "Building $($Side.Name): $($Side.Label)"
        # Build output goes to the host so it never mixes into this function's return value.
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Side.Source 'build.ps1') release -OutputPath $exe |
            Out-Host
        if ($LASTEXITCODE -ne 0) { throw "The $($Side.Name) build failed." }
        Set-Content -LiteralPath $stamp -Value $current
    }
    if (-not (Test-Path $exe)) { throw "No $($Side.Name) build at $exe; run without -NoBuild." }
    return $exe
}

function Reset-Data([string] $Data, [string] $SettingsSource) {
    if (-not $KeepData -and (Test-Path $Data)) { Remove-Item -LiteralPath $Data -Recurse -Force }
    New-Item -ItemType Directory -Force $Data | Out-Null
    if ($SettingsSource) { Copy-Item -LiteralPath $SettingsSource -Destination (Join-Path $Data 'settings.ini') -Force }
}

function Wait-Window([int] $ProcessId) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline) {
        $window = [AIODevCompare.Win32]::LargestWindow([uint32] $ProcessId)
        if ($window -ne [IntPtr]::Zero) { return $window }
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 100
    }
    return [IntPtr]::Zero
}

Stop-Compare
if ($Stop) { return }

$settingsSource = $null
if ($Settings -and $MySettings) { throw 'Use either -Settings or -MySettings.' }
if ($Settings) { $settingsSource = (Resolve-Path $Settings).Path }
if ($MySettings) {
    $settingsSource = Join-Path $env:APPDATA 'AIODev/settings.ini'
    if (-not (Test-Path $settingsSource)) { throw "No settings at $settingsSource." }
}

$screens = [System.Windows.Forms.Screen]::AllScreens
$screen = if ($Monitor -ge 0) {
    if ($Monitor -ge $screens.Count) { throw "Monitor $Monitor does not exist; there are $($screens.Count)." }
    $screens[$Monitor]
} else { [System.Windows.Forms.Screen]::PrimaryScreen }
$area = $screen.WorkingArea
if ($CandidateOnly -and $PSBoundParameters.ContainsKey('Base')) { throw 'Use either -Base or -CandidateOnly.' }
$width = if ($CandidateOnly) { $area.Width } else { [int][Math]::Floor($area.Width / 2) }

$sides = @(if (-not $CandidateOnly) { Resolve-Side $Base 'Base' }; Resolve-Side $Candidate 'Candidate')
$running = @()
for ($i = 0; $i -lt $sides.Count; $i++) {
    $side = $sides[$i]
    $exe = Build-Side $side
    $data = Join-Path $root "$($side.Name.ToLower())/data"
    Reset-Data $data $settingsSource
    $instance = "compare-$($side.Name.ToLower())"
    $process = Start-Process -FilePath $exe -ArgumentList @('--instance', $instance, '--data-dir', "`"$data`"") `
        -WorkingDirectory $here -PassThru
    $window = Wait-Window $process.Id
    if ($window -eq [IntPtr]::Zero) { throw "$($side.Name) opened no window; see $data for its log." }
    [AIODevCompare.Win32]::ShowWindow($window, 9) | Out-Null
    [AIODevCompare.Win32]::PlaceFrame($window, $area.X + $i * $width, $area.Y, $width, $area.Height)
    $running += [pscustomobject]@{ name = $side.Name; pid = $process.Id; exe = (Resolve-Path $exe).Path }
    $place = if ($CandidateOnly) { 'full' } elseif ($i -eq 0) { 'left' } else { 'right' }
    Write-Output ("{0,-9} {1,-5} {2}  pid {3}" -f $side.Name, $place, $side.Label, $process.Id)
}
$running | ConvertTo-Json | Set-Content -LiteralPath $record
Write-Output 'Close with .\tools\compare.ps1 -Stop'
