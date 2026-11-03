<#
.SYNOPSIS
Builds two versions of AIODev and opens them side by side with the same settings.

.DESCRIPTION
Each side is a git ref (branch, tag or commit) or the path of a checkout or worktree. A ref is checked
out into a cached worktree under build/compare; a path is built in place, uncommitted changes
included. Both sides are release builds in their own folders and run as separate instances with
their own data folders, so they never share a window, a control pipe, settings or saved layout.
Base opens on the left half of the monitor and Candidate on the right, each at the same size.
-CandidateOnly skips Base and keeps Candidate's default window size.

Each candidate is its own compare session, so previews from several worktrees or agent sessions stay
open together. Running again with the same candidate replaces only that session's windows.

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
Closes the current checkout's compare windows; -Candidate names another session, -All closes every one.
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')]
    [string] $Base = 'main',

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Stop')]
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

    # Build and open only the candidate at the app's default window size.
    [Parameter(ParameterSetName = 'Run')]
    [switch] $CandidateOnly,

    # Zero-based monitor index in the order Windows lists screens; the primary monitor by default.
    [Parameter(ParameterSetName = 'Run')]
    [int] $Monitor = -1,

    [Parameter(ParameterSetName = 'Stop', Mandatory)]
    [switch] $Stop,

    # With -Stop, close every compare session rather than only this candidate's.
    [Parameter(ParameterSetName = 'Stop')]
    [switch] $All
)

$ErrorActionPreference = 'Stop'
$here = (Get-Location).Path

# The compare folder lives in the main checkout so every worktree shares one ref cache. Each candidate
# gets its own session folder for checkout builds, data and its running record.
$common = (& git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir).Trim()
if ($LASTEXITCODE -ne 0) { throw 'compare.ps1 must run from inside an AIODev checkout.' }
$repo = Split-Path $common -Parent
$root = Join-Path $repo 'build/compare'
$sessions = Join-Path $root 'sessions'
$refs = Join-Path $root 'refs'
New-Item -ItemType Directory -Force $sessions, $refs | Out-Null

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

function Stop-Session([string] $Record) {
    if (-not (Test-Path $Record)) { return }
    foreach ($side in (Get-Content $Record -Raw | ConvertFrom-Json)) {
        $process = Get-Process -Id $side.pid -ErrorAction SilentlyContinue
        # Closing the window only hides AIODev to the tray, so end the throwaway instance and its
        # shells outright. The path check keeps a reused process ID from hitting another program.
        if ($process -and $process.Path -eq $side.exe) {
            # A child may already be exiting; taskkill reports that on stderr, which is not a failure.
            & cmd.exe /d /c "taskkill /PID $($side.pid) /T /F >nul 2>&1"
            $process.WaitForExit(5000) | Out-Null
        }
    }
    Remove-Item $Record -Force
}

function Test-Checkout([string] $Path) {
    (Test-Path (Join-Path $Path 'build.ps1')) -and (Test-Path (Join-Path $Path 'src'))
}

# A session is named by its candidate: the checkout folder, or the ref as typed, so -Stop finds it
# again after the ref moves.
function Get-SessionKey([string] $Spec) {
    $path = if ([IO.Path]::IsPathRooted($Spec)) { $Spec } else { Join-Path $here $Spec }
    $identity = if (Test-Checkout $path) {
        'path:' + (Resolve-Path $path).Path.TrimEnd('\', '/').ToLowerInvariant()
    } else { "ref:$Spec" }
    $hash = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))
    return -join ($hash[0..3] | ForEach-Object { $_.ToString('x2') })
}

# Removes cached ref builds unused for two weeks, unless a session is still running one.
function Clear-OldRefs {
    $inUse = @(Get-ChildItem $sessions -Filter running.json -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).exe })
    foreach ($cache in Get-ChildItem $refs -Directory) {
        $stamp = Join-Path $cache.FullName 'aiodev.exe.source'
        $used = if (Test-Path $stamp) { (Get-Item $stamp).LastWriteTimeUtc } else { $cache.LastWriteTimeUtc }
        if ($used -gt [DateTime]::UtcNow.AddDays(-14)) { continue }
        if ($inUse -contains (Join-Path $cache.FullName 'aiodev.exe')) { continue }
        & git -C $repo worktree remove --force (Join-Path $cache.FullName 'src') 2>&1 | Out-Null
        Remove-Item -LiteralPath $cache.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# A side is a checkout path when one exists there; otherwise a ref checked out into the cache.
function Resolve-Side([string] $Spec, [string] $Name) {
    $path = if ([IO.Path]::IsPathRooted($Spec)) { $Spec } else { Join-Path $here $Spec }
    if (Test-Checkout $path) {
        $source = (Resolve-Path $path).Path
        $branch = (& git -C $source rev-parse --abbrev-ref HEAD).Trim()
        $commit = (& git -C $source rev-parse --short HEAD).Trim()
        $dirty = if (& git -C $source status --porcelain) { '+dirty' } else { '' }
        return [pscustomobject]@{
            Name = $Name; Source = $source; Label = "$branch@$commit$dirty"; Cached = $false
            Exe = Join-Path $session "$($Name.ToLower())/aiodev.exe"
        }
    }
    $commit = (& git -C $repo rev-parse --verify --quiet "$Spec^{commit}")
    if ($LASTEXITCODE -ne 0 -or -not $commit) { throw "$Name '$Spec' is neither a checkout folder nor a git ref." }
    $commit = $commit.Trim()
    # One cache per commit, shared by every session and never moved to another commit, so a running
    # preview's source and executable stay put.
    $cache = Join-Path $refs $commit.Substring(0, 12)
    $short = (& git -C $repo rev-parse --short $commit).Trim()
    return [pscustomobject]@{
        Name = $Name; Source = Join-Path $cache 'src'; Label = "$Spec@$short"; Cached = $true
        Commit = $commit; Exe = Join-Path $cache 'aiodev.exe'
    }
}

function Invoke-Build($Side) {
    Write-Host "Building $($Side.Name): $($Side.Label)"
    # Build output goes to the host so it never mixes into a function's return value.
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Side.Source 'build.ps1') release -OutputPath $Side.Exe |
        Out-Host
    if ($LASTEXITCODE -ne 0) { throw "The $($Side.Name) build failed." }
}

function Build-Side($Side) {
    $exe = $Side.Exe
    if ($NoBuild) {
        if (-not (Test-Path $exe)) { throw "No $($Side.Name) build at $exe; run without -NoBuild." }
        return $exe
    }
    # A working checkout always rebuilds.
    if (-not $Side.Cached) {
        Invoke-Build $Side
        return $exe
    }
    # Another session may be building the same commit; wait for it rather than building over it.
    $lock = [Threading.Mutex]::new($false, "AIODevCompare-$($Side.Commit)")
    try {
        try { $lock.WaitOne() | Out-Null } catch [Threading.AbandonedMutexException] {}
        $stamp = "$exe.source"
        if ((Test-Path $exe) -and (Test-Path $stamp) -and (Get-Content $stamp -Raw).Trim() -eq $Side.Commit) {
            # Marks the cache as used so Clear-OldRefs keeps it.
            (Get-Item $stamp).LastWriteTimeUtc = [DateTime]::UtcNow
            return $exe
        }
        if (-not (Test-Path (Join-Path $Side.Source '.git'))) {
            & git -C $repo worktree add --detach $Side.Source $Side.Commit 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Cannot create a worktree for $($Side.Label) at $($Side.Source)." }
        }
        Invoke-Build $Side
        Set-Content -LiteralPath $stamp -Value $Side.Commit
    } finally {
        $lock.ReleaseMutex()
        $lock.Dispose()
    }
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

if ($Stop -and $All) {
    Get-ChildItem $sessions -Filter running.json -Recurse | ForEach-Object { Stop-Session $_.FullName }
    return
}
$key = Get-SessionKey $Candidate
$session = Join-Path $sessions $key
$record = Join-Path $session 'running.json'
Stop-Session $record
if ($Stop) { return }
Clear-OldRefs

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
    $data = Join-Path $session "$($side.Name.ToLower())/data"
    Reset-Data $data $settingsSource
    $instance = "cmp-$key-$($side.Name.ToLower())"
    $process = Start-Process -FilePath $exe -ArgumentList @('--instance', $instance, '--data-dir', "`"$data`"") `
        -WorkingDirectory $here -PassThru
    $window = Wait-Window $process.Id
    if ($window -eq [IntPtr]::Zero) { throw "$($side.Name) opened no window; see $data for its log." }
    [AIODevCompare.Win32]::ShowWindow($window, 9) | Out-Null
    if (-not $CandidateOnly) {
        [AIODevCompare.Win32]::PlaceFrame($window, $area.X + $i * $width, $area.Y, $width, $area.Height)
    }
    $running += [pscustomobject]@{ name = $side.Name; pid = $process.Id; exe = (Resolve-Path $exe).Path }
    $place = if ($CandidateOnly) { 'default' } elseif ($i -eq 0) { 'left' } else { 'right' }
    Write-Output ("{0,-9} {1,-5} {2}  pid {3}" -f $side.Name, $place, $side.Label, $process.Id)
}
ConvertTo-Json @($running) | Set-Content -LiteralPath $record
$close = if ($Candidate -eq '.') { '' } else { " -Candidate $Candidate" }
Write-Output "Close with .\tools\compare.ps1 -Stop$close"
