# Updates the installed AIODev to the latest release while it runs; AIODev's Update AIODev command runs
# this copy, installed beside it. It downloads the latest release's install.ps1, which is pinned to that
# release's ZIP and SHA-256, and runs it unless that release is already installed. The installer moves the
# running files aside, so AIODev keeps running until it restarts into the new ones.
#
# Every line goes to -Log; its last line is the message AIODev shows. The exit code says what happened:
#   0      a newer AIODev is installed, by this run or an earlier one; restarting AIODev starts it
#   3      the running AIODev is the latest release, or newer
#   other  the update failed and the install is unchanged
param(
    [Parameter(Mandatory)]
    [string] $Log,

    # The running AIODev's version, such as 0.15.0; an untagged build passes none and always updates.
    [string] $RunningVersion = '',

    # Tests point this at a pinned install.ps1 they serve.
    [string] $InstallerUrl = 'https://github.com/ChaseHaley/AIODev/releases/latest/download/install.ps1'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[IO.File]::WriteAllText($Log, '')
function Write-Log([string] $Line) { [IO.File]::AppendAllText($Log, "$Line`r`n") }

# 1.2.3 from 1.2.3 or 1.2.3-beta.1; $null for anything else.
function Get-VersionNumber([string] $Text) {
    if ($Text -match '^(\d+)\.(\d+)\.(\d+)') { return [version] "$($Matches[1]).$($Matches[2]).$($Matches[3])" }
    return $null
}

try {
    $destination = Join-Path $env:LOCALAPPDATA 'Programs\AIODev'
    if ($PSScriptRoot.TrimEnd('\') -ne $destination.TrimEnd('\')) {
        throw "Only an installed AIODev updates itself; this one runs from $PSScriptRoot."
    }
    Write-Log "Downloading $InstallerUrl"
    $download = Join-Path ([IO.Path]::GetTempPath()) "AIODev-update-$([guid]::NewGuid()).ps1"
    try {
        Invoke-WebRequest -Uri $InstallerUrl -OutFile $download -UseBasicParsing -TimeoutSec 60
        $installer = [IO.File]::ReadAllText($download)
    } finally { Remove-Item -LiteralPath $download -ErrorAction SilentlyContinue }
    if ($installer -notmatch "\`$releaseArchiveUrl = '[^']*/v([^/']+)/[^/']+'") {
        throw "The latest release's install.ps1 names no release archive."
    }
    $latest = $Matches[1]
    $running = Get-VersionNumber $RunningVersion
    $latestNumber = Get-VersionNumber $latest
    if ($RunningVersion -eq $latest -or ($running -and $latestNumber -and $running -gt $latestNumber)) {
        Write-Log "AIODev $RunningVersion is up to date."
        exit 3
    }
    $installedVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $destination 'aiodev.exe')).ProductVersion
    if ($installedVersion -ne $latest) {
        Write-Log "Installing AIODev $latest"
        & ([scriptblock]::Create($installer)) *>&1 | ForEach-Object { Write-Log "$_" }
    }
    Write-Log "AIODev $latest is installed."
    exit 0
} catch {
    Write-Log "$($_.Exception.Message)"
    exit 1
}
