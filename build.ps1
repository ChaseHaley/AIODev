[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('debug', 'release', 'package', 'run', 'test', 'check', 'verify')]
    [string] $Task = 'debug',

    [Parameter(Position = 1)]
    [string] $Package
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

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
    # With -print-linker-flags, Odin compiles and keeps the object but leaves the resource and link steps to us.
    $printed = @(& odin build src "-out:$Output" @Mode @flags @resource -keep-temp-files -print-linker-flags)
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
}

function Build-Release {
    New-Item -ItemType Directory -Force build/release | Out-Null
    Build-App @('-o:speed', '-subsystem:windows') 'build/release/aiodev.exe'
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

switch ($Task) {
    'verify' {
        $buildId = Get-BuildId
        # Literal single quotes keep a numeric Git hash a string in Odin.
        Build-App @('-debug', '-subsystem:console', '-define:AIO_CONTROL=true',
            "-define:AIO_BUILD_ID='$buildId'") 'build/aiodev-verify.exe'
        foreach ($name in $toolPackages) {
            Invoke-Odin build "tools/$name" "-out:build/$name.exe" -debug '-subsystem:console' @flags
        }
    }
    'debug' { Build-App @('-debug', '-subsystem:console') }
    'release' { Build-Release }
    'package' {
        Build-Release
        $buildId = Get-BuildId
        $stage = 'build/package/AIODev'
        New-Item -ItemType Directory -Force $stage | Out-Null
        Copy-Item -LiteralPath 'build/release/aiodev.exe' -Destination "$stage/aiodev.exe"
        Copy-Item -LiteralPath 'tools/install.ps1' -Destination "$stage/install.ps1"
        Copy-Item -LiteralPath 'vendor/ghostty/LICENSE' -Destination "$stage/Ghostty-LICENSE.txt"
        Copy-Conpty $stage
        Copy-Item -LiteralPath 'vendor/conpty/LICENSE' -Destination "$stage/ConPTY-LICENSE.txt"
        [IO.File]::WriteAllText((Join-Path $PWD "$stage/build.txt"), "$buildId`r`n")
        $archive = "build/AIODev-$buildId-windows-x64.zip"
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
        foreach ($name in $sourcePackages) {
            Invoke-Odin check "src/$name" -no-entry-point @flags
        }
        if (Get-ChildItem src -Filter *.odin -File) {
            Invoke-Odin check src @flags
            Invoke-Odin check src @appFlags
            Invoke-Odin check src '-define:AIO_CONTROL=true' @appFlags
        }
        foreach ($name in $toolPackages) {
            Invoke-Odin check "tools/$name" @flags
        }
    }
    'test' {
        $targets = if ($Package) { @($Package) } else { $testPackages }
        if ($targets.Count -eq 0) { throw 'No test packages found under tests/.' }
        New-Item -ItemType Directory -Force build/test | Out-Null
        Copy-Conpty 'build/test'
        foreach ($name in $targets) {
            if (-not (Test-Path "tests/$name")) { throw "No tests at tests/$name." }
            Invoke-Odin test "tests/$name" "-out:build/test/$name.exe" -debug -keep-executable @flags
        }
    }
}
