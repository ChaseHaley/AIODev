[CmdletBinding()]
param(
    [string] $Revision
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$vendor = Join-Path $root 'vendor/ghostty'
$source = Join-Path $root '.deps/ghostty'
$output = Join-Path $root '.deps/ghostty-out'

if (-not $Revision) { $Revision = (Get-Content (Join-Path $vendor 'REVISION') -Raw).Trim() }

if (-not (Test-Path $source)) {
    git init --quiet $source
    git -C $source remote add origin https://github.com/ghostty-org/ghostty.git
}
git -C $source fetch --quiet --depth 1 origin $Revision
git -C $source checkout --quiet --detach FETCH_HEAD

Push-Location $source
try {
    zig build -Demit-lib-vt=true -Doptimize=ReleaseFast --prefix $output
}
finally {
    Pop-Location
}

Copy-Item (Join-Path $output 'lib/ghostty-vt-static.lib') $vendor -Force
Remove-Item (Join-Path $vendor 'include') -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $vendor 'include') | Out-Null
Copy-Item (Join-Path $source 'include/ghostty') (Join-Path $vendor 'include/ghostty') -Recurse
Copy-Item (Join-Path $source 'LICENSE') (Join-Path $vendor 'LICENSE') -Force
Set-Content (Join-Path $vendor 'REVISION') $Revision -NoNewline
