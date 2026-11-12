# Installs AIODev for the current user, from either of two places:
#   - an extracted release ZIP: run this file and it installs the package beside it;
#   - the web: irm https://github.com/ChaseHaley/AIODev/releases/latest/download/install.ps1 | iex
#     The copy attached to each release names that release's ZIP and SHA-256 (tools/release.ps1 fills them
#     in); it downloads the ZIP, refuses it unless the hash matches, and installs from it.
# Everything runs inside one script block, so a download cut short fails to parse rather than running part
# of the installer, and nothing set here leaks into the session of someone who piped it into iex.
& {
    $ErrorActionPreference = 'Stop'
    # tools/release.ps1 replaces these two lines in the copy it attaches to a release.
    $releaseArchiveUrl = ''
    $releaseSha256 = ''

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

    # Downloads the release ZIP into $Directory, checks it against the pinned hash and extracts it there.
    # Returns the package folder. Hashing and extraction use .NET directly, so a PowerShell whose modules
    # fail to load (for example powershell.exe started from pwsh) still installs.
    function Get-ReleasePackage([string] $Directory) {
        $archive = Join-Path $Directory 'AIODev.zip'
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $releaseArchiveUrl -OutFile $archive -UseBasicParsing
        $stream = [IO.File]::OpenRead($archive)
        try {
            $sha256 = [Security.Cryptography.SHA256]::Create()
            $actual = -join ($sha256.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
        } finally { $stream.Dispose() }
        if ($actual -ne $releaseSha256) {
            throw "The download's SHA-256 is $actual, not the release's $releaseSha256. Nothing was installed."
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $Directory)
        return Join-Path $Directory 'AIODev'
    }

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

    $destination = Join-Path $env:LOCALAPPDATA 'Programs\AIODev'
    # A running AIODev holds its files open, so copying would stop partway and leave aio.exe and aiodev.exe
    # from different builds.
    $installed = Join-Path $destination 'aiodev.exe'
    $running = @(Get-Process -Name aiodev -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $installed })
    if ($running.Count -gt 0) {
        throw 'AIODev is running. Quit it, including from the notification area, then install again.'
    }

    $download = $null
    if ($PSCommandPath) {
        $source = $PSScriptRoot
        if (-not (Test-Path -LiteralPath (Join-Path $source 'aiodev.exe') -PathType Leaf)) {
            throw 'Extract the AIODev package, then run its install.ps1.'
        }
    } elseif (-not $releaseArchiveUrl) {
        throw ('This install.ps1 names no release. Run ' +
            "'irm https://github.com/ChaseHaley/AIODev/releases/latest/download/install.ps1 | iex'," +
            ' or extract a release ZIP and run its install.ps1.')
    } else {
        $download = Join-Path ([IO.Path]::GetTempPath()) "AIODev-install-$([guid]::NewGuid())"
        New-Item -ItemType Directory $download | Out-Null
    }
    try {
        if ($download) {
            Write-Output "Downloading $releaseArchiveUrl"
            $source = Get-ReleasePackage $download
        }
        Install-PackageFiles $source $destination
    } finally {
        if ($download) { Remove-Item -LiteralPath $download -Recurse -Force -ErrorAction SilentlyContinue }
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
        [void] [AIODevInstall.Native]::SendMessageTimeout([IntPtr] 0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2,
            5000, [ref] $result)
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'AIODev.lnk'
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $installed
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
}
