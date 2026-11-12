<#
.SYNOPSIS
Writes the install.ps1 attached to an AIODev release, pinned to that release's archive.

.DESCRIPTION
Fills tools/install.ps1's release archive URL and SHA-256 with the given release's, so the web
installer (irm .../releases/latest/download/install.ps1 | iex) installs exactly that archive. The
release workflow runs it after packaging.

.EXAMPLE
./tools/release-installer.ps1 v0.15.0 dist/AIODev-v0.15.0-windows-x64.zip dist/install.ps1
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

$hash = (Get-Content -LiteralPath "$Archive.sha256" -Raw).Split(' ')[0]
$pins = [ordered] @{
    releaseArchiveUrl = "https://github.com/ChaseHaley/AIODev/releases/download/$Tag/$(Split-Path $Archive -Leaf)"
    releaseSha256 = $hash
}
$script = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'install.ps1') -Raw
foreach ($pin in $pins.GetEnumerator()) {
    $blank = "`$$($pin.Key) = ''"
    if (([regex]::Matches($script, [regex]::Escape($blank))).Count -ne 1) {
        throw "tools/install.ps1 must assign $blank exactly once."
    }
    $script = $script.Replace($blank, "`$$($pin.Key) = '$($pin.Value)'")
}
[IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path), $script)
