# Where AIODev finds Cosmos, the framework it builds on (D-108), and which commit of it tools/cosmos.json
# pins. Dot-sourced by build.ps1 and the scripts that compile AIODev packages themselves.

# Runs git for its answer. Windows PowerShell 5.1 turns a native command's stderr into a terminating
# error under 'Stop', so a git that says no on stderr is read by its exit code instead.
function Invoke-GitProbe([string[]] $Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & git @Arguments 2>$null } finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = "$output".Trim() }
}

function Get-CosmosPin {
    $spec = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'cosmos.json') -Raw | ConvertFrom-Json
    if ("$($spec.commit)" -notmatch '^[0-9a-f]{40}$') { throw 'tools/cosmos.json names no full Cosmos commit.' }
    if (-not $spec.url) { throw 'tools/cosmos.json names no Cosmos repository URL.' }
    return $spec
}

# The Cosmos checkout to build against: $Explicit, then COSMOS_ROOT, then Cosmos beside the folder that
# holds $Repository's main checkout, which every worktree of it shares through the common git directory.
function Resolve-CosmosRoot([string] $Repository, [string] $Explicit) {
    $root = $Explicit
    if (-not $root) { $root = $env:COSMOS_ROOT }
    if (-not $root) {
        $common = & git -C $Repository rev-parse --path-format=absolute --git-common-dir
        if ($LASTEXITCODE -ne 0 -or -not $common) { throw "Cannot find the git directory of $Repository." }
        $root = Join-Path (Split-Path (Split-Path $common.Trim() -Parent) -Parent) 'Cosmos'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'tools/build-common.ps1'))) {
        throw "No Cosmos checkout at $root. Clone $((Get-CosmosPin).url) there, or pass -Cosmos or set COSMOS_ROOT."
    }
    return (Resolve-Path -LiteralPath $root).Path
}

# Whether $Root is a clean checkout of $Commit. A git error counts as not.
function Test-CosmosPinned([string] $Root, [string] $Commit) {
    $head = Invoke-GitProbe @('-C', $Root, 'rev-parse', 'HEAD')
    if ($head.Code -ne 0 -or $head.Output -ne $Commit) { return $false }
    $status = Invoke-GitProbe @('-C', $Root, 'status', '--porcelain')
    return ($status.Code -eq 0 -and -not $status.Output)
}

# A clean copy of the pinned commit, for builds that ship: $Root itself when it is one, otherwise the
# commit exported from $Root into $Repository/build/deps, fetched from the pin's URL when $Root lacks it.
function Get-PinnedCosmos([string] $Repository, [string] $Root, $Pin) {
    if (Test-CosmosPinned $Root $Pin.commit) { return $Root }
    $target = Join-Path $Repository "build/deps/cosmos-$($Pin.commit)"
    if (Test-Path -LiteralPath (Join-Path $target 'tools/build-common.ps1')) { return $target }
    if ((Invoke-GitProbe @('-C', $Root, 'cat-file', '-e', "$($Pin.commit)^{commit}")).Code -ne 0) {
        & git -C $Root fetch --quiet $Pin.url $Pin.commit
        if ($LASTEXITCODE -ne 0) { throw "Cannot fetch Cosmos $($Pin.commit) from $($Pin.url)." }
    }
    $archive = "$target.zip"
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    & git -C $Root archive --format=zip "--output=$archive" $Pin.commit
    if ($LASTEXITCODE -ne 0) { throw "Cannot export Cosmos $($Pin.commit)." }
    try { Expand-Archive -LiteralPath $archive -DestinationPath $target } finally { Remove-Item -LiteralPath $archive }
    return $target
}
