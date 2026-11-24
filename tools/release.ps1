<#
.SYNOPSIS
Starts an AIODev release: checks main, tags v<Version> and pushes both.

.DESCRIPTION
From a clean main in sync with the remote: runs build.ps1 check, tags v<Version>, then pushes main and
the tag. The tag push starts .github/workflows/release.yml, which builds the package on a GitHub-hosted
runner from the tagged source and publishes the release. Versions with a suffix such as -beta.1 are
published as prereleases. The workflow builds against the Cosmos commit tools/cosmos.json pins, so when
that commit is on local Cosmos main but not yet on GitHub, Cosmos main is pushed first.

.EXAMPLE
./tools/release.ps1 0.15.0 -DryRun

.EXAMPLE
./tools/release.ps1 0.15.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$')]
    [string] $Version,

    [string] $Remote = 'upstream',

    # Runs every check, then stops before tagging or pushing.
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $repo
$tag = "v$Version"

if ((git branch --show-current) -ne 'main') { throw 'Release from main.' }
if (git status --porcelain) { throw 'Commit or stash changes first; releases are built from a clean tree.' }
if (git tag --list $tag) { throw "$tag already exists locally." }
git fetch --quiet $Remote main --tags
if (git ls-remote --tags $Remote "refs/tags/$tag") { throw "$tag already exists on $Remote." }
if (git rev-list "HEAD..$Remote/main") { throw "$Remote/main has commits that local main lacks." }

& pwsh -NoLogo -NoProfile -File (Join-Path $repo 'build.ps1') check
if ($LASTEXITCODE -ne 0) { throw 'build.ps1 check failed.' }

# The release workflow checks out the Cosmos commit tools/cosmos.json pins, so that commit must be on
# Cosmos's GitHub main before the tag goes up. A pin that local Cosmos main holds is pushed with it.
. (Join-Path $repo 'tools/cosmos.ps1')
$cosmosPin = Get-CosmosPin
$cosmos = Get-CosmosCheckout $repo ''
# A remote without main yet, as before the first release that needs Cosmos, has published nothing.
$null = Invoke-GitProbe @('-C', $cosmos, 'fetch', '--quiet', 'origin', 'main')
$cosmosPublished =
    (Invoke-GitProbe @('-C', $cosmos, 'merge-base', '--is-ancestor', $cosmosPin.commit, 'origin/main')).Code -eq 0
if (-not $cosmosPublished -and
    (Invoke-GitProbe @('-C', $cosmos, 'merge-base', '--is-ancestor', $cosmosPin.commit, 'main')).Code -ne 0) {
    throw "The pinned Cosmos commit $($cosmosPin.commit) is not on Cosmos main."
}

if ($DryRun) {
    $cosmosNote = if ($cosmosPublished) { '' } else { ' after pushing Cosmos main to its origin' }
    Write-Output ("Dry run complete. A release would tag $tag at $(git rev-parse --short HEAD) and push it to " +
        "$Remote$cosmosNote.")
    return
}

if (-not $cosmosPublished) { git -C $cosmos push origin main }

git tag --annotate $tag --message "AIODev $tag"
git push $Remote main
git push $Remote $tag
Write-Output "Pushed $tag. The release workflow builds and publishes it:"
Write-Output 'https://github.com/ChaseHaley/AIODev/actions/workflows/release.yml'
