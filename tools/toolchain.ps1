<#
.SYNOPSIS
Installs the pinned Odin and Zig that build AIODev releases.

.DESCRIPTION
Downloads each archive, refuses it unless its SHA-256 matches the pin below, and extracts it under
-Destination. Writes the directories holding odin.exe and zig.exe; with -GitHubPath it also puts them on
the PATH of the GitHub Actions steps that follow. MSVC and the Windows SDK come from the machine.

.EXAMPLE
./tools/toolchain.ps1 -Destination build/toolchain
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Destination,

    [switch] $GitHubPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Odin dev-2026-09 is commit a2fb372, the nightly AIODev is developed against. Zig 0.17.1 builds the pinned
# libghostty-vt release (D-090).
$tools = @(
    @{
        Name = 'odin'
        Url = 'https://github.com/odin-lang/Odin/releases/download/dev-2026-09/odin-windows-amd64-dev-2026-09.zip'
        Sha256 = '8ed8abd95b82e0af1eb7e86cb75f380fd8bde104947721817b35929f5fc19388'
    }
    @{
        Name = 'zig'
        Url = 'https://ziglang.org/download/0.17.1/zig-x86_64-windows-0.17.1.zip'
        Sha256 = 'b03f477a1943673e02aca0f570e8030dffd536ce1f45cbc4d3326ec31159562e'
    }
)

New-Item -ItemType Directory -Force $Destination | Out-Null
foreach ($tool in $tools) {
    $archive = Join-Path $Destination (Split-Path $tool.Url -Leaf)
    Write-Host "Downloading $($tool.Url)"
    Invoke-WebRequest $tool.Url -OutFile $archive
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $tool.Sha256) { throw "$archive has SHA-256 $actual; tools/toolchain.ps1 pins $($tool.Sha256)." }
    $root = Join-Path $Destination $tool.Name
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $archive -DestinationPath $root
    $exe = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter "$($tool.Name).exe")
    if ($exe.Count -ne 1) { throw "Expected one $($tool.Name).exe in $archive." }
    $directory = $exe[0].DirectoryName
    if ($GitHubPath) { Add-Content -LiteralPath $env:GITHUB_PATH -Value $directory }
    Write-Output $directory
}
