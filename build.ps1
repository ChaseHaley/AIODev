[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('debug', 'release', 'package', 'run', 'test', 'check', 'verify')]
    [string] $Task = 'debug',

    [Parameter(Position = 1)]
    [string] $Package,

    [string] $OutputPath,

    # Exact Odin test names, comma-separated; use with one package for a focused rerun.
    [ValidatePattern('^[A-Za-z0-9_.,]*$')]
    [string] $TestNames,

    [ValidateSet('All', 'Fast', 'Native')]
    [string] $TestLane = 'All',

    [ValidateRange(1, 900)]
    [int] $TestTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if ($OutputPath -and $Task -ne 'release') { throw 'OutputPath is supported for release builds.' }
if ($TestNames -and ($Task -ne 'test' -or -not $Package)) { throw 'TestNames requires test and a package.' }
if ($TestLane -ne 'All' -and ($Task -ne 'test' -or $Package -ne 'app')) {
    throw 'TestLane requires test app.'
}

function Invoke-Odin {
    & odin @args
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Get-Packages([string] $Root) {
    if (-not (Test-Path $Root)) { return @() }
    Get-ChildItem $Root -Directory |
        Where-Object { Get-ChildItem $_.FullName -Filter *.odin -File } |
        ForEach-Object Name
}

$sourcePackages = @(Get-Packages 'src')
$testPackages = @(Get-Packages 'tests')
$toolPackages = @(Get-Packages 'tools')
$vetPackages = @('main') + $sourcePackages + $toolPackages +
    ($testPackages | ForEach-Object { "${_}_test" })

$flags = @(
    '-collection:aio=src'
    '-vet'
    '-vet-cast'
    '-vet-tabs'
    '-vet-using-param'
    "-vet-packages:$($vetPackages -join ',')"
    '-strict-style'
    '-warnings-as-errors'
    '-disallow-do'
)

$resource = @()
if (Test-Path 'assets/aiodev.rc') { $resource = @('-resource:assets/aiodev.rc') }

New-Item -ItemType Directory -Force build | Out-Null

function Build-NativeLibrary([string] $Name, [string] $Source, [string] $CompilerFlags) {
    $nativeRoot = Join-Path $PSScriptRoot 'build/native'
    New-Item -ItemType Directory -Force $nativeRoot | Out-Null
    $library = Join-Path $nativeRoot "$Name.lib"
    $source = Join-Path $PSScriptRoot $Source
    if ((Test-Path $library) -and (Get-Item $library).LastWriteTimeUtc -gt (Get-Item $source).LastWriteTimeUtc) { return }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $visualStudio) { throw "MSVC C++ tools are required to build $Name." }
    $vcvars = Join-Path $visualStudio 'VC/Auxiliary/Build/vcvars64.bat'
    $object = Join-Path $nativeRoot "$Name.obj"
    $batch = Join-Path $nativeRoot "compile-$Name.cmd"
    @("@echo off", "call `"$vcvars`" >nul 2>&1", 'if errorlevel 1 exit /b 1',
      "cl /nologo /c $CompilerFlags /Fo`"$object`" `"$source`"",
      'if errorlevel 1 exit /b 1', "lib /nologo /out:`"$library`" `"$object`"") | Set-Content -LiteralPath $batch
    & cmd /d /c $batch
    if ($LASTEXITCODE -ne 0) { throw "$Name library build failed." }
}
function Build-NativeLibraries {
    # C++/WinRT keeps the notification ABI and COM event ownership out of the Odin UI code.
    Build-NativeLibrary 'notifications' 'native/windows_notifications.cpp' '/std:c++20 /EHsc /MT /O2 /W4 /WX'
    Build-NativeLibrary 'md4c' 'vendor/md4c/md4c.c' '/MT /O2 /W3'
}
if ($Task -ne 'test') { Build-NativeLibraries }

# The bundled ConPTY (D-044) loads from beside each executable that opens consoles.
function Copy-Conpty([string] $Directory) {
    New-Item -ItemType Directory -Force $Directory | Out-Null
    foreach ($name in @('conpty.dll', 'OpenConsole.exe')) {
        Copy-Item -LiteralPath "vendor/conpty/$name" -Destination (Join-Path $Directory $name) -Force
    }
}

function Split-Arguments([string] $Line) {
    [regex]::Matches($Line, '(?:[^\s"]+|"[^"]*")+') | ForEach-Object { $_.Value -replace '"', '' }
}

# libghostty-vt's Zig core is one large non-COMDAT section that the linker would place after
# AIODev's code, so any source change moved the VT parser's alignment and TermBench by 2 to 3
# percent. Linking that object first gives the parser the same address in every build.
function Build-App([string[]] $Mode, [string] $Output = 'build/aiodev.exe') {
    $buildId = Get-BuildId
    $kind = if ($Mode -contains '-define:AIO_CONTROL=true') { 'verify' }
        elseif ($Mode -contains '-o:speed') { 'release' } else { 'debug' }
    # Literal single quotes keep a numeric Git hash a string in Odin.
    $identity = @("-define:AIO_BUILD_ID='$buildId'", "-define:AIO_BUILD_KIND='$kind'")
    # With -print-linker-flags, Odin compiles and keeps the object but leaves the resource and link steps to us.
    $printed = @(& odin build src "-out:$Output" @Mode @identity @flags @resource -keep-temp-files -print-linker-flags)
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $linkLine = $printed | Where-Object { $_ -match '-OUT:' } | Select-Object -Last 1
    if (-not $linkLine) { throw 'Odin did not print linker flags.' }
    $linkArgs = @(Split-Arguments $linkLine)
    $msvcLib = $linkArgs | Where-Object { $_ -match '^/LIBPATH:(.*[/\\]MSVC[/\\][^/\\]+)[/\\]lib[/\\]x64$' } | Select-Object -First 1
    if (-not $msvcLib) { throw 'Odin linker flags name no MSVC library path.' }
    $msvcBin = Join-Path ($msvcLib -replace '^/LIBPATH:(.*)[/\\]lib[/\\]x64$', '$1') 'bin/Hostx64/x64'

    if ($resource) {
        $sdkLib = $linkArgs | Where-Object { $_ -match '^/LIBPATH:.*[/\\]Lib[/\\][^/\\]+[/\\]um[/\\]x64$' } | Select-Object -First 1
        if (-not $sdkLib) { throw 'Odin linker flags name no Windows SDK library path.' }
        $rc = $sdkLib -replace '^/LIBPATH:(.*)[/\\]Lib[/\\]([^/\\]+)[/\\]um[/\\]x64$', '$1/bin/$2/x64/rc.exe'
        $rcLine = $printed | Where-Object { $_ -match '^/nologo /fo ' } | Select-Object -Last 1
        if (-not $rcLine) { throw 'Odin did not print resource compiler flags.' }
        & $rc @(Split-Arguments $rcLine)
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    $ghostty = 'vendor/ghostty/ghostty-vt-static.lib'
    $core = 'build/ghostty-vt-core.obj'
    if (-not (Test-Path $core) -or (Get-Item $core).LastWriteTimeUtc -lt (Get-Item $ghostty).LastWriteTimeUtc) {
        $member = & (Join-Path $msvcBin 'lib.exe') /nologo /list $ghostty |
            Where-Object { $_ -like '*ghostty-vt-static_zcu.obj' }
        if (@($member).Count -ne 1) { throw "Expected one Zig core object in $ghostty." }
        & (Join-Path $msvcBin 'lib.exe') /nologo "/extract:$member" "/out:$core" $ghostty
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    & (Join-Path $msvcBin 'link.exe') $core @linkArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $stem = $Output -replace '\.exe$', ''
    Remove-Item -LiteralPath "$stem.obj", "$stem.ll" -ErrorAction SilentlyContinue
    Copy-Conpty (Split-Path $Output)
    $themeDestination = Join-Path (Split-Path $Output) 'themes'
    New-Item -ItemType Directory -Force $themeDestination | Out-Null
    # Start empty so themes removed from the repository do not linger in the build.
    Get-ChildItem $themeDestination -Filter *.json -File | Remove-Item -Force
    Copy-Item -Path 'themes/*.json' -Destination $themeDestination -Force
    # The aio command line ships beside every app build; the app adds its directory to each shell's PATH.
    [string[]] $cliMode = if ($Mode -contains '-o:speed') { '-o:speed' } else { '-debug' }
    $serverName = Split-Path $Output -Leaf
    Invoke-Odin build src/cli "-out:$(Join-Path (Split-Path $Output) 'aio.exe')" @cliMode `
        '-subsystem:console' "-define:AIO_SERVER_NAME='$serverName'" @flags
}

function Build-Release([string] $Destination = 'build/release/aiodev.exe') {
    # Resolve against the PowerShell location; .NET's GetFullPath uses the process directory,
    # which Set-Location does not change, so builds landed wherever the shell started.
    $resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
    New-Item -ItemType Directory -Force (Split-Path $resolvedOutput) | Out-Null
    Build-App @('-o:speed', '-subsystem:windows') $resolvedOutput
}

function Get-BuildId {
    try {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return 'unknown' }
        $head = & git rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { return 'unknown' }
        $status = & git status --porcelain 2>$null
        if ($LASTEXITCODE -ne 0) { return 'unknown' }
        if ($status) { return "$head+dirty" }
        return "$head"
    } catch {
        return 'unknown'
    }
}

# Library packages expose API that tests and later features use, so only application code
# is held to the unused-procedure check.
$appFlags = @($flags | Where-Object { $_ -notlike '-vet-packages:*' }) +
    @('-vet-packages:main', '-vet-unused-procedures')

# Generated bindings mirror their foreign sources; the style rules apply to hand-written application
# code. Tests and tools are not gated yet; they carry the same drift and a separate pass owns it.
function Invoke-StyleCheck {
    Invoke-Odin build tools/stylecheck '-out:build/stylecheck.exe' -debug '-subsystem:console' @flags
    $files = Get-ChildItem src -Recurse -Filter *.odin -File |
        Where-Object {
            $_.Name -ne 'win32_windows.odin' -and $_.FullName -notmatch '\\(ghostty|dwrite|shaders)\\'
        } |
        ForEach-Object FullName
    & build/stylecheck.exe @files
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

switch ($Task) {
    'verify' {
        Build-App @('-debug', '-subsystem:console', '-define:AIO_CONTROL=true') 'build/aiodev-verify.exe'
        foreach ($name in $toolPackages) {
            Invoke-Odin build "tools/$name" "-out:build/$name.exe" -debug '-subsystem:console' @flags
        }
    }
    'debug' { Build-App @('-debug', '-subsystem:console') }
    'release' {
        if ($OutputPath) { Build-Release $OutputPath }
        else { Build-Release }
    }
    'package' {
        Build-Release
        $buildId = Get-BuildId
        $stage = 'build/package/AIODev'
        # Start empty: files left by another branch's package must never ship (WORK-252).
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        New-Item -ItemType Directory -Force $stage | Out-Null
        Copy-Item -LiteralPath 'build/release/aiodev.exe' -Destination "$stage/aiodev.exe"
        Copy-Item -LiteralPath 'build/release/aio.exe' -Destination "$stage/aio.exe"
        Copy-Item -LiteralPath 'tools/install.ps1' -Destination "$stage/install.ps1"
        Copy-Item -LiteralPath 'LICENSE' -Destination "$stage/LICENSE.txt"
        Copy-Item -LiteralPath 'THIRD_PARTY_NOTICES.txt' -Destination "$stage/THIRD_PARTY_NOTICES.txt"
        Copy-Conpty $stage
        Copy-Item -LiteralPath 'themes' -Destination $stage -Recurse -Force
        [IO.File]::WriteAllText((Join-Path $PWD "$stage/build.txt"), "$buildId`r`n")
        # install.ps1 installs exactly what this list names, so the stage above is the one file list.
        $stageRoot = (Resolve-Path -LiteralPath $stage).Path
        $manifest = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File |
            ForEach-Object { $_.FullName.Substring($stageRoot.Length + 1) } |
            Where-Object { $_ -ne 'install.ps1' } | Sort-Object)
        [IO.File]::WriteAllText((Join-Path $stageRoot 'files.txt'), (($manifest | ForEach-Object { "$_`r`n" }) -join ''))
        # A clean checkout of a release tag names the archive after the tag; anything else uses the revision.
        $label = $buildId
        if ($buildId -notmatch '\+dirty$|^unknown$') {
            $tag = & git describe --tags --exact-match HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and $tag) { $label = $tag.Trim() }
        }
        $archive = "build/AIODev-$label-windows-x64.zip"
        Compress-Archive -LiteralPath $stage -DestinationPath $archive -Force
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText((Join-Path $PWD "$archive.sha256"), "$hash  $(Split-Path $archive -Leaf)`r`n")
        Write-Output "Package: $archive"
    }
    'run' {
        Build-App @('-debug', '-subsystem:console')
        & build/aiodev.exe
    }
    'check' {
        Invoke-StyleCheck
        foreach ($name in $sourcePackages) {
            Invoke-Odin check "src/$name" -no-entry-point @flags
        }
        # The headless backend (WORK-349) must keep compiling beside the Win32 one.
        Invoke-Odin check src/platform -no-entry-point '-define:AIO_HEADLESS=true' @flags
        if (Get-ChildItem src -Filter *.odin -File) {
            Invoke-Odin check src @flags
            Invoke-Odin check src @appFlags
            Invoke-Odin check src '-define:AIO_CONTROL=true' @appFlags
            Invoke-Odin check src '-define:AIO_HEADLESS=true' @appFlags
            Invoke-Odin check src '-define:AIO_HEADLESS=true' '-define:AIO_CONTROL=true' @appFlags
        }
        foreach ($name in $toolPackages) {
            Invoke-Odin check "tools/$name" @flags
        }
    }
    'test' {
        . "$PSScriptRoot/tools/test-suite.ps1"
        Invoke-TestSuite -TestPackages $testPackages -Package $Package -TestNames $TestNames `
            -TestLane $TestLane -TestTimeoutSeconds $TestTimeoutSeconds -Flags $flags -Resource $resource
    }
}
