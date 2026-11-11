[CmdletBinding()]
param(
    [string] $Zig = 'zig',
    [string] $Cpu
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$vendor = Join-Path $root 'vendor/ghostty'
$deps = Join-Path $root '.deps'
$pin = @{}
foreach ($line in Get-Content (Join-Path $vendor 'VERSION')) {
    if ($line -match '^\s*([^#=\s]+)\s*=\s*(\S+)\s*$') { $pin[$Matches[1]] = $Matches[2] }
}
foreach ($key in 'version', 'source_sha256', 'deps_sha256') {
    if (-not $pin[$key]) { throw "vendor/ghostty/VERSION is missing '$key'" }
}

$version = $pin['version']
$name = "libghostty-vt-$version"
$source = Join-Path $deps $name
$system = Join-Path $deps "$name-deps"
$output = Join-Path $deps "$name-out"
New-Item -ItemType Directory -Force $deps | Out-Null

function Get-PinnedTarball([string] $file, [string] $sha256) {
    $path = Join-Path $deps $file
    $valid = (Test-Path $path) -and (Get-FileHash $path -Algorithm SHA256).Hash -eq $sha256
    if (-not $valid) {
        $url = "https://release.files.ghostty.org/libghostty-vt/$version/$file"
        Write-Host "Downloading $url"
        Invoke-WebRequest $url -OutFile $path
        $actual = (Get-FileHash $path -Algorithm SHA256).Hash
        if ($actual -ne $sha256) { throw "$file has SHA256 $actual; vendor/ghostty/VERSION pins $sha256" }
    }
    # Extract fresh every time so patches always apply to the pristine release.
    $extracted = Join-Path $deps ($file -replace '\.tar\.gz$', '')
    Remove-Item $extracted -Recurse -Force -ErrorAction SilentlyContinue
    tar -xzf $path -C $deps
    if (-not (Test-Path $extracted)) { throw "$file did not extract to $extracted" }
}

Get-PinnedTarball "$name.tar.gz" $pin['source_sha256']
Get-PinnedTarball "$name-deps.tar.gz" $pin['deps_sha256']

# The extracted source sits inside this repository's work tree; the ceiling keeps
# git apply from resolving patch paths against the AIODev repository instead.
$env:GIT_CEILING_DIRECTORIES = $deps
$patches = Join-Path $vendor 'patches'
if (Test-Path $patches) {
    foreach ($patch in Get-ChildItem $patches -Filter '*.patch' | Sort-Object Name) {
        Write-Host "Applying $($patch.Name)"
        git -C $source apply --verbose $patch.FullName
    }
}

$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $deps 'zig-global-cache'
$arguments = @('build', '--prefix', $output, '--system', $system, '-Doptimize=ReleaseFast')
if ($Cpu) { $arguments += "-Dcpu=$Cpu" }
Remove-Item $output -Recurse -Force -ErrorAction SilentlyContinue
Push-Location $source
try {
    & $Zig @arguments
}
finally {
    Pop-Location
}

Copy-Item (Join-Path $output 'lib/ghostty-vt-static.lib') $vendor -Force
Remove-Item (Join-Path $vendor 'include') -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $vendor 'include') | Out-Null
Copy-Item (Join-Path $output 'include/ghostty') (Join-Path $vendor 'include/ghostty') -Recurse
Copy-Item (Join-Path $source 'LICENSE') (Join-Path $vendor 'LICENSE') -Force
