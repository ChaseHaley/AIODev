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

# The pin in $Path, by default this checkout's tools/cosmos.json.
function Get-CosmosPin([string] $Path = (Join-Path $PSScriptRoot 'cosmos.json')) {
    $spec = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ("$($spec.commit)" -notmatch '^[0-9a-f]{40}$') { throw "$Path names no full Cosmos commit." }
    if (-not $spec.url) { throw "$Path names no Cosmos repository URL." }
    return $spec
}

# The folder that holds $Repository's main checkout, which every worktree of it shares through the common
# git directory.
function Get-MainCheckout([string] $Repository) {
    $common = & git -C $Repository rev-parse --path-format=absolute --git-common-dir
    if ($LASTEXITCODE -ne 0 -or -not $common) { throw "Cannot find the git directory of $Repository." }
    return Split-Path $common.Trim() -Parent
}

# The Cosmos checkout named for $Repository: $Explicit, then COSMOS_ROOT, then Cosmos beside its main
# checkout. Tools that work on Cosmos's own history, such as a release, use this one.
function Get-CosmosCheckout([string] $Repository, [string] $Explicit) {
    $root = $Explicit
    if (-not $root) { $root = $env:COSMOS_ROOT }
    if (-not $root) { $root = Join-Path (Split-Path (Get-MainCheckout $Repository) -Parent) 'Cosmos' }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'tools/build-common.ps1'))) {
        throw "No Cosmos checkout at $root. Clone $((Get-CosmosPin).url) there, or pass -Cosmos or set COSMOS_ROOT."
    }
    return (Resolve-Path -LiteralPath $root).Path
}

# The Cosmos to build against. A checkout named by $Explicit or COSMOS_ROOT is used as it is. Otherwise
# the pinned commit is: the Cosmos beside the main checkout when it is a clean checkout of the pin, else
# a shared copy of the pin (Get-CosmosCopy), so any branch or ref builds whatever that checkout holds.
function Resolve-CosmosRoot([string] $Repository, [string] $Explicit) {
    $root = Get-CosmosCheckout $Repository $Explicit
    if ($Explicit -or $env:COSMOS_ROOT) { return $root }
    return Get-CosmosCopy $Repository $root (Get-CosmosPin)
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

# A clean checkout of the pinned commit for local builds: $Root itself when it is one, otherwise a
# detached worktree of $Root's repository at build/cosmos/<commit>/src in the main checkout, shared by
# every worktree and session and fetched from the pin's URL when $Root lacks the commit. $Root's own
# checkout is untouched.
function Get-CosmosCopy([string] $Repository, [string] $Root, $Pin) {
    if (Test-CosmosPinned $Root $Pin.commit) { return $Root }
    $caches = [IO.Path]::GetFullPath((Join-Path (Get-MainCheckout $Repository) 'build/cosmos'))
    $cache = Join-Path $caches $Pin.commit.Substring(0, 12)
    $target = Join-Path $cache 'src'
    # Marks the copy as used so Clear-OldCosmos keeps it.
    $stamp = Join-Path $cache 'used'
    if (Test-CosmosPinned $target $Pin.commit) {
        [IO.File]::WriteAllText($stamp, $Pin.commit)
        return $target
    }
    # Sessions build concurrently; one makes the copy while the others wait for it.
    $lock = [Threading.Mutex]::new($false, "AIODevCosmos-$($Pin.commit)")
    try {
        try { $lock.WaitOne() | Out-Null } catch [Threading.AbandonedMutexException] {}
        if (-not (Test-CosmosPinned $target $Pin.commit)) {
            if (Test-Path -LiteralPath $target) {
                throw "$target is not a clean checkout of Cosmos $($Pin.commit); remove it with git worktree remove."
            }
            if ((Invoke-GitProbe @('-C', $Root, 'cat-file', '-e', "$($Pin.commit)^{commit}")).Code -ne 0) {
                if ((Invoke-GitProbe @('-C', $Root, 'fetch', '--quiet', $Pin.url, $Pin.commit)).Code -ne 0) {
                    throw "Cannot fetch Cosmos $($Pin.commit) from $($Pin.url)."
                }
            }
            New-Item -ItemType Directory -Force $cache | Out-Null
            if ((Invoke-GitProbe @('-C', $Root, 'worktree', 'add', '--detach', $target, $Pin.commit)).Code -ne 0) {
                throw "Cannot check out Cosmos $($Pin.commit) at $target."
            }
            Clear-OldCosmos $Root $caches $cache
        }
        [IO.File]::WriteAllText($stamp, $Pin.commit)
    } finally {
        $lock.ReleaseMutex()
        $lock.Dispose()
    }
    return $target
}

# Removes pinned copies unused for two weeks, as tools/compare.ps1 does for its ref builds, except $Keep.
# Runs when a new copy is made, so a pin bump retires the copies older pins left.
function Clear-OldCosmos([string] $Root, [string] $Caches, [string] $Keep) {
    foreach ($cache in Get-ChildItem -LiteralPath $Caches -Directory) {
        if ($cache.FullName -eq $Keep) { continue }
        $stamp = Join-Path $cache.FullName 'used'
        $used = if (Test-Path -LiteralPath $stamp) { (Get-Item -LiteralPath $stamp).LastWriteTimeUtc } else {
            $cache.LastWriteTimeUtc }
        if ($used -gt [DateTime]::UtcNow.AddDays(-14)) { continue }
        $null = Invoke-GitProbe @('-C', $Root, 'worktree', 'remove', '--force', (Join-Path $cache.FullName 'src'))
        Remove-Item -LiteralPath $cache.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $null = Invoke-GitProbe @('-C', $Root, 'worktree', 'prune')
}

# The -Cosmos to build the AIODev checkout at $Source with: a clean copy of the commit its own pin names,
# so a ref whose build.ps1 would build against whatever ..\Cosmos holds still builds at its pin. Empty
# when COSMOS_ROOT names a checkout, which that build.ps1 then uses, or when $Source predates the pin.
function Get-CheckoutCosmos([string] $Repository, [string] $Source) {
    $pin = Join-Path $Source 'tools/cosmos.json'
    if ($env:COSMOS_ROOT -or -not (Test-Path -LiteralPath $pin)) { return '' }
    return Get-CosmosCopy $Repository (Get-CosmosCheckout $Repository '') (Get-CosmosPin $pin)
}
