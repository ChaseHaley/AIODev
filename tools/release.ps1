<#
.SYNOPSIS
Publishes an AIODev release to GitHub.

.DESCRIPTION
From a clean main in sync with the remote and with the GitHub CLI signed in: runs build.ps1 check,
tags v<Version>, builds the package, writes notes from feat, fix and perf commit subjects since the
previous tag, pushes main and the tag, and uploads the zip and its SHA256. Versions below 1.0 and
versions with a suffix such as -beta.1 are prereleases.

.EXAMPLE
./tools/release.ps1 0.2.0 -DryRun

.EXAMPLE
./tools/release.ps1 0.2.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$')]
    [string] $Version,

    [string] $Remote = 'upstream',

    # Builds, tags and packages locally, then stops before anything leaves the machine.
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $repo
$tag = "v$Version"

# Shows the build's output as it runs and returns it.
function Invoke-Build([string] $Task) {
    $lines = @(& pwsh -NoLogo -NoProfile -File (Join-Path $repo 'build.ps1') $Task |
        ForEach-Object { Write-Host $_; $_ })
    if ($LASTEXITCODE -ne 0) { throw "build.ps1 $Task failed." }
    return $lines
}

if ((git branch --show-current) -ne 'main') { throw 'Release from main.' }
if (git status --porcelain) { throw 'Commit or stash changes first; releases are built from a clean tree.' }
if (git tag --list $tag) { throw "$tag already exists locally." }
if (-not $DryRun) {
    gh auth status *> $null
    git fetch --quiet $Remote main --tags
    if (git ls-remote --tags $Remote "refs/tags/$tag") { throw "$tag already exists on $Remote." }
    if (git rev-list "HEAD..$Remote/main") { throw "$Remote/main has commits that local main lacks." }
}

$previous = try { git describe --tags --abbrev=0 2>$null } catch { $null }

$null = Invoke-Build check
git tag --annotate $tag --message "AIODev $tag"
try {
    $packaged = Invoke-Build package
}
catch {
    git tag --delete $tag | Out-Null
    throw
}

# build.ps1 names the archive and reports it; it uses the tag only when it finds HEAD tagged and clean.
$archive = @($packaged | Where-Object { $_ -match '^Package: (.+)$' } | ForEach-Object { $Matches[1] })[0]
if (-not $archive -or -not (Test-Path -LiteralPath $archive)) { throw 'build.ps1 package reported no archive.' }
if ((Split-Path $archive -Leaf) -notlike "*-$tag-*") { throw "Expected the archive $archive to carry $tag." }
$hash = (Get-Content -LiteralPath "$archive.sha256" -Raw).Split(' ')[0]

# Release notes list user-facing Conventional Commits since the previous tag.
$range = if ($previous) { "$previous..HEAD" } else { 'HEAD' }
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
    "Download ``$(Split-Path $archive -Leaf)``, extract it, and run ``AIODev\install.ps1`` in PowerShell.",
    'It installs per user to `%LOCALAPPDATA%\Programs\AIODev`, adds `aio` to your PATH and creates a Start menu shortcut.',
    '',
    "SHA256: ``$hash``"
))
$notesPath = "build/release-notes-$tag.md"
[IO.File]::WriteAllLines((Join-Path $repo $notesPath), $notes)

if ($DryRun) {
    git tag --delete $tag | Out-Null
    Write-Output "Dry run complete. Package: $archive"
    Write-Output "Notes: $notesPath"
    return
}

git push $Remote main
git push $Remote $tag
$prerelease = @(if ($Version -match '^0\.|-') { '--prerelease' })
gh release create $tag $archive "$archive.sha256" --title "AIODev $tag" --notes-file $notesPath @prerelease
Write-Output "Released $tag"
