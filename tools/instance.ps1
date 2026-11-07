# The app's instance command line and data layout for PowerShell launchers. src/instance/instance.odin
# owns them (FLAG_INSTANCE, FLAG_DATA_DIR, SETTINGS_FILE, APP_NAME); dot-source this file instead of
# retyping them. These launchers start release builds, including older refs, so they use the public
# flags rather than tools/aioctl, which drives only control-enabled verification builds.

$AIODevInstanceFlag = '--instance'
$AIODevDataDirFlag = '--data-dir'
$AIODevSettingsFile = 'settings.ini'

# Arguments for Start-Process that run an instance with its own data folder. The folder is quoted
# because Start-Process joins the arguments into one command line.
function Get-AIODevInstanceArguments([string] $Name, [string] $DataDir) {
    return @($AIODevInstanceFlag, $Name, $AIODevDataDirFlag, "`"$DataDir`"")
}

# Whether an aiodev process was started as the named instance.
function Test-AIODevInstanceRunning([string] $Name) {
    $pattern = "$([regex]::Escape($AIODevInstanceFlag))\s+$([regex]::Escape($Name))\b"
    return [bool] (Get-Process aiodev -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match $pattern })
}

# The settings file of the default instance, which keeps its data in the roaming profile.
function Get-AIODevUserSettingsPath {
    return Join-Path $env:APPDATA "AIODev/$AIODevSettingsFile"
}
