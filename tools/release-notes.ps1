<#
.SYNOPSIS
Writes the GitHub release notes for a tagged AIODev package.

.DESCRIPTION
Lists the feat, fix and perf Conventional Commit subjects since the previous tag, then install steps
and the archive's SHA-256 from its .sha256 file. The release workflow runs it after packaging.

.EXAMPLE
./tools/release-notes.ps1 v0.15.0 dist/AIODev-v0.15.0-windows-x64.zip build/release-notes.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string] $Tag,

    [Parameter(Mandatory, Position = 1)]
    [string] $Archive,

    [Parameter(Mandatory, Position = 2)]
    [string] $Path
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$hash = (Get-Content -LiteralPath "$Archive.sha256" -Raw).Split(' ')[0]
$previous = try { git describe --tags --abbrev=0 "$Tag^" 2>$null } catch { $null }
$range = if ($previous) { "$previous..$Tag" } else { $Tag }
$subjects = @(git log $range --no-merges --format='%s')

$sections = [ordered] @{ 'Features' = '^feat(\(.+\))?!?: '; 'Fixes' = '^fix(\(.+\))?!?: '; 'Performance' = '^perf(\(.+\))?!?: ' }
$notes = [System.Collections.Generic.List[string]]::new()
foreach ($section in $sections.GetEnumerator()) {
    $lines = @($subjects | Where-Object { $_ -match $section.Value } | ForEach-Object { "- $($_ -replace $section.Value, '')" })
    if ($lines.Count -eq 0) { continue }
    $notes.Add("## $($section.Key)")
    $notes.Add('')
    $notes.AddRange([string[]] $lines)
    $notes.Add('')
}
$notes.AddRange([string[]] @(
    '## Install',
    '',
    'Quit AIODev, then in PowerShell, to install or upgrade:',
    '',
    '```powershell',
    'irm https://github.com/ChaseHaley/AIODev/releases/latest/download/install.ps1 | iex',
    '```',
    '',
    "Or download ``$(Split-Path $Archive -Leaf)``, extract it, and run",
    '`powershell -ExecutionPolicy Bypass -File AIODev\install.ps1`.',
    'Either way it installs per user to `%LOCALAPPDATA%\Programs\AIODev`, adds `aio` to your PATH and creates a',
    'Start menu shortcut. To uninstall, run',
    '`powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\AIODev\uninstall.ps1"`.',
    '',
    "SHA256: ``$hash``",
    '',
    '## Code signing policy',
    '',
    'See the [code signing policy](https://github.com/ChaseHaley/AIODev#code-signing-policy) for how releases are signed,',
    'who approves them, and the privacy statement.'
))
[IO.File]::WriteAllLines($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path), $notes)
