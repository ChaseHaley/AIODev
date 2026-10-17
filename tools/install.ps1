[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'aiodev.exe'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw 'Extract the AIODev package, then run its install.ps1.'
}
$destination = Join-Path $env:LOCALAPPDATA 'Programs\AIODev'
New-Item -ItemType Directory -Force $destination | Out-Null
foreach ($name in @('aiodev.exe', 'Ghostty-LICENSE.txt', 'build.txt')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $destination $name)
}
$shell = New-Object -ComObject WScript.Shell
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'AIODev.lnk'
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $destination 'aiodev.exe'
$shortcut.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')
$shortcut.IconLocation = "$($shortcut.TargetPath),0"
$shortcut.Save()
Write-Output "Installed: $destination"
Write-Output "Start menu shortcut: $shortcutPath"
