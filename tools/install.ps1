[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'aiodev.exe'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw 'Extract the AIODev package, then run its install.ps1.'
}
# Installs exactly the files build.ps1's package stage lists in files.txt, refusing a package that lacks
# any of them. Themes the user may have edited are kept; the theme schema is the app's and is replaced.
function Install-PackageFiles([string] $Source, [string] $Destination) {
    $manifest = Join-Path $Source 'files.txt'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "The package has no files.txt." }
    $names = @(Get-Content -LiteralPath $manifest | Where-Object { $_ -ne '' })
    $missing = @($names | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Source $_) -PathType Leaf) })
    if ($missing.Count -gt 0) { throw "The package is incomplete; missing: $($missing -join ', ')." }
    foreach ($name in $names) {
        $target = Join-Path $Destination $name
        $theme = $name -like 'themes\*'
        if ($theme -and (Split-Path $name -Leaf) -ne 'theme.schema.json' -and (Test-Path -LiteralPath $target)) {
            continue
        }
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item -LiteralPath (Join-Path $Source $name) -Destination $target
    }
    # Earlier packages shipped per-component license files; THIRD_PARTY_NOTICES.txt now holds them all.
    foreach ($name in @('Ghostty-LICENSE.txt', 'ConPTY-LICENSE.txt')) {
        Remove-Item -LiteralPath (Join-Path $Destination $name) -ErrorAction SilentlyContinue
    }
}

$destination = Join-Path $env:LOCALAPPDATA 'Programs\AIODev'
Install-PackageFiles $PSScriptRoot $destination
# Adds a directory to the user's PATH once. Raw registry access keeps %VARIABLE% entries unexpanded,
# which [Environment]::SetEnvironmentVariable would flatten.
function Add-UserPath([Microsoft.Win32.RegistryKey] $Key, [string] $Directory) {
    $raw = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    if ($Key.GetValueNames() -contains 'Path') { $kind = $Key.GetValueKind('Path') }
    $entries = @(([string] $Key.GetValue('Path', '', $raw)) -split ';' | Where-Object { $_ -ne '' })
    $present = $entries | Where-Object { $_.TrimEnd('\') -eq $Directory.TrimEnd('\') }
    if ($present) { return $false }
    $Key.SetValue('Path', (($entries + $Directory) -join ';'), $kind)
    return $true
}

# Coding agents run aio from any terminal, not only AIODev panes, so it goes on the user's PATH.
$environment = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
try { $pathAdded = Add-UserPath $environment $destination } finally { $environment.Dispose() }
if ($pathAdded) {
    Add-Type -Namespace AIODevInstall -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam,
    uint flags, uint timeout, out UIntPtr result);
'@
    # WM_SETTINGCHANGE tells Explorer, and terminals it starts later, that the environment changed.
    $result = [UIntPtr]::Zero
    [void] [AIODevInstall.Native]::SendMessageTimeout([IntPtr] 0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000,
        [ref] $result)
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
if ($pathAdded) {
    Write-Output "Added $destination to your PATH; terminals opened from now on can run aio."
} else {
    Write-Output "aio is on your PATH: $destination"
}
