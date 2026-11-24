[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('debug', 'release', 'package', 'run', 'test', 'check', 'verify', 'types')]
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
    [int] $TestTimeoutSeconds = 300,

    # The Cosmos checkout to build against instead of the one tools/cosmos.ps1 finds.
    [string] $Cosmos
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if ($OutputPath -and $Task -ne 'release') { throw 'OutputPath is supported for release builds.' }
if ($TestNames -and ($Task -ne 'test' -or -not $Package)) { throw 'TestNames requires test and a package.' }
if ($TestLane -ne 'All' -and ($Task -ne 'test' -or $Package -ne 'app')) {
    throw 'TestLane requires test app.'
}

# AIODev builds on Cosmos, the owner's framework for his family of apps (D-108). A package ships only from
# a clean copy of the commit tools/cosmos.json pins. Other builds use a checkout named by -Cosmos or
# COSMOS_ROOT as it is, and otherwise the pinned commit (Resolve-CosmosRoot); a checkout that is not
# exactly the pin marks the build dirty, so no release can come from it.
. "$PSScriptRoot/tools/cosmos.ps1"
$cosmosPin = Get-CosmosPin
$cosmosSkew = $false
if ($Task -eq 'package') {
    $cosmosRoot = Get-PinnedCosmos $PSScriptRoot (Get-CosmosCheckout $PSScriptRoot $Cosmos) $cosmosPin
} else {
    $cosmosRoot = Resolve-CosmosRoot $PSScriptRoot $Cosmos
    if (-not (Test-CosmosPinned $cosmosRoot $cosmosPin.commit)) {
        $cosmosSkew = $true
        Write-Warning ("Cosmos at $cosmosRoot is not a clean checkout of the pinned " +
            "$($cosmosPin.commit.Substring(0, 12)); builds are marked dirty.")
    }
}
. "$cosmosRoot/tools/build-common.ps1"

$sourcePackages = @(Get-Packages 'src')
$testPackages = @(Get-Packages 'tests')
$toolPackages = @(Get-Packages 'tools')
$vetPackages = @('main') + $sourcePackages + $toolPackages +
    ($testPackages | ForEach-Object { "${_}_test" })

# Cosmos vets its own packages; these flags vet AIODev's.
$flags = @('-collection:aio=src', "-collection:cosmos=$cosmosRoot/src") + $CosmosStrictFlags +
    "-vet-packages:$($vetPackages -join ',')"

$resource = @()
if (Test-Path 'assets/aiodev.rc') { $resource = @('-resource:assets/aiodev.rc') }
$cliResource = @()
if (Test-Path 'assets/aio.rc') { $cliResource = @('-resource:assets/aio.rc') }

# assets/version.rc gives aiodev.exe and aio.exe a version resource from this header. A release tag such
# as v1.2.3-beta.1 gives 1,2,3,0 and its own text; any other build is 0,0,0,0, named by its build ID.
function Write-VersionHeader([string] $BuildId, [string] $Version) {
    $number = '0,0,0,0'
    $text = "dev $BuildId"
    if ($Version -match '^(\d+)\.(\d+)\.(\d+)') {
        $number = "$($Matches[1]),$($Matches[2]),$($Matches[3]),0"
        $text = $Version
    }
    $header = "#define AIO_VERSION_NUMBER $number`r`n#define AIO_VERSION_TEXT `"$text`"`r`n"
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'build/version.h'), $header)
}

New-Item -ItemType Directory -Force build | Out-Null

function Build-LuaJIT {
    $nativeRoot = Join-Path $PSScriptRoot 'build/native'
    $vendorRoot = Join-Path $PSScriptRoot 'vendor/luajit'
    $library = Join-Path $nativeRoot 'luajit.lib'
    $version = Join-Path $vendorRoot 'VERSION'
    if ((Test-Path -LiteralPath $library) -and (Get-Item $library).LastWriteTimeUtc -ge (Get-Item $version).LastWriteTimeUtc) { return }
    $vcvars = Get-Vcvars64 'LuaJIT'
    New-Item -ItemType Directory -Force $nativeRoot | Out-Null
    $sourceRoot = Join-Path $nativeRoot 'luajit-src'
    if (Test-Path -LiteralPath $sourceRoot) { Remove-Item -LiteralPath $sourceRoot -Recurse -Force }
    Copy-Item -LiteralPath $vendorRoot -Destination $sourceRoot -Recurse -Force
    $script = Join-Path $sourceRoot 'src/msvcbuild.bat'
    $text = [IO.File]::ReadAllText($script).Replace("`r`n", "`n")
    # Keep upstream sources pristine; the library and build tools use md4c's static CRT.
    $text = $text.Replace('@set LJCOMPILE=cl ', '@set LJCOMPILE=cl /MT /DLUAJIT_ENABLE_CHECKHOOK ')
    $text = $text.Replace('/MD', '/MT')
    # Upstream's failure labels only print a message, so propagate their failure explicitly.
    $text = $text.Replace("@goto :END`n:FAIL", "@exit /b 1`n:FAIL")
    $text = $text.Replace("script`n:END", "script`n@exit /b 1`n:END")
    [IO.File]::WriteAllText($script, $text.Replace("`n", "`r`n"), [Text.Encoding]::ASCII)
    # LuaJIT raises every Lua error as an SEH exception, even one a pcall catches. Its
    # error-severity code (0xE24C4A0x) is fatal to Odin's test runner and alarms crash
    # tooling, so raise the same code with informational severity (0x624C4A0x) instead.
    # The internal unwinder is not an option on Windows x64: its interpreter frame does
    # not save r12-r15 or xmm6-xmm15, so an error returns from lua_pcall with clobbered
    # callee-saved registers.
    $errorSource = Join-Path $sourceRoot 'src/lj_err.c'
    $errorText = [IO.File]::ReadAllText($errorSource)
    $upstreamCode = "#define LJ_EXCODE`t`t((DWORD)0xe24c4a00)"
    if (-not $errorText.Contains($upstreamCode)) { throw 'LuaJIT lj_err.c no longer defines LJ_EXCODE as expected.' }
    [IO.File]::WriteAllText($errorSource, $errorText.Replace($upstreamCode, "#define LJ_EXCODE`t`t((DWORD)0x624c4a00)"), [Text.Encoding]::ASCII)
    $batch = Join-Path $nativeRoot 'compile-luajit.cmd'
    @("@echo off", "call `"$vcvars`" >nul 2>&1", 'if errorlevel 1 exit /b 1',
      "pushd `"$sourceRoot/src`"", 'if errorlevel 1 exit /b 1',
      'call msvcbuild.bat static', 'if errorlevel 1 exit /b 1', 'popd') |
        Set-Content -LiteralPath $batch
    & cmd /d /c $batch
    $produced = Join-Path $sourceRoot 'src/lua51.lib'
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $produced)) {
        throw 'LuaJIT static library build failed; see the MSVC output above.'
    }
    Copy-Item -LiteralPath $produced -Destination $library -Force
}

function Build-NativeLibraries {
    # cosmos:platform links the notification and WebView2 bridges from the Cosmos checkout.
    Build-CosmosNative $cosmosRoot
    Build-NativeLibrary $PSScriptRoot 'md4c' 'vendor/md4c/md4c.c' '/MT /O2 /W3'
    Build-LuaJIT
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
function Build-App([string[]] $Mode, [string] $Output = 'build/aiodev.exe', [string] $AlternateServer = '') {
    $buildId = Get-BuildId
    $kind = if ($Mode -contains '-define:AIO_CONTROL=true') { 'verify' }
        elseif ($Mode -contains '-o:speed') { 'release' } else { 'debug' }
    $version = (Get-ReleaseTag $buildId) -replace '^v', ''
    Write-VersionHeader $buildId $version
    # Literal single quotes keep a numeric Git hash a string in Odin. aio.exe gets the same identity,
    # so aio can tell when it talks to an AIODev from another build.
    $identity = @("-define:AIO_BUILD_ID='$buildId'", "-define:AIO_BUILD_KIND='$kind'",
        "-define:AIO_BUILD_VERSION='$version'")
    # With -print-linker-flags, Odin compiles and keeps the object but leaves the resource and link steps to us.
    $printed = @(& odin build src "-out:$Output" @Mode @identity @flags @resource -keep-temp-files -print-linker-flags)
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    # aioctl doctor compares the build with the sources it came from, Cosmos's included.
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'build/cosmos-root.txt'), $cosmosRoot)
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
    # The family's bundled themes come from Cosmos. Start empty so themes removed there do not linger.
    Get-ChildItem $themeDestination -Filter *.json -File | Remove-Item -Force
    Copy-Item -Path "$cosmosRoot/themes/*.json" -Destination $themeDestination -Force
    # The Neovim plugin ships beside aiodev.exe and aio.exe; its path comes from AIODEV_CLI.
    $nvimDestination = Join-Path (Split-Path $Output) 'nvim'
    Remove-Item -LiteralPath $nvimDestination -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath 'nvim' -Destination $nvimDestination -Recurse
    # PSVim ships beside aiodev.exe under modules\PSVim so PowerShell panes can Import-Module PSVim.
    Copy-PSVim (Split-Path $Output)
    # The aio command line ships beside every app build; the app puts its directory first on each
    # shell's PATH.
    [string[]] $cliMode = if ($Mode -contains '-o:speed') { '-o:speed' } else { '-debug' }
    $serverName = Split-Path $Output -Leaf
    [string[]] $alternate = if ($AlternateServer) { @("-define:AIO_SERVER_ALTERNATE='$AlternateServer'") } else { @() }
    Invoke-Odin build src/cli "-out:$(Join-Path (Split-Path $Output) 'aio.exe')" @cliMode `
        '-subsystem:console' "-define:AIO_SERVER_NAME='$serverName'" @identity @alternate @flags @cliResource
}

function Copy-PSVim([string] $Root) {
    $dest = Join-Path $Root 'modules\PSVim'
    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue

    $manifestPath = 'tools/psvim.json'
    $sourceDir = $null
    if (Test-Path -LiteralPath $manifestPath) {
        $spec = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($spec.url -and $spec.sha256) {
            $cacheRoot = Join-Path 'build\cache\psvim' $spec.version
            $zipFile = Join-Path $cacheRoot "PSVim-$($spec.version).zip"
            $extractDir = Join-Path $cacheRoot 'module'
            if (-not (Test-Path -LiteralPath (Join-Path $extractDir 'PSVim.dll'))) {
                New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
                Invoke-WebRequest -Uri $spec.url -OutFile $zipFile -UseBasicParsing
                $actual = (Get-FileHash -LiteralPath $zipFile -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actual -ne $spec.sha256.ToLowerInvariant()) {
                    Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue
                    throw "PSVim archive SHA-256 mismatch: expected $($spec.sha256), got $actual"
                }
                if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
                Expand-Archive -LiteralPath $zipFile -DestinationPath $extractDir -Force
            }
            $sourceDir = $extractDir
        }
    }

    if (-not $sourceDir) {
        $sibling = Resolve-Path -LiteralPath '..\PSVim\module' -ErrorAction SilentlyContinue
        if ($sibling -and (Test-Path -LiteralPath (Join-Path $sibling.Path 'PSVim.dll'))) {
            $sourceDir = $sibling.Path
        }
    }

    if (-not $sourceDir) { return }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    foreach ($file in @('PSVim.psd1', 'PSVim.psm1', 'PSVim.dll')) {
        $src = Join-Path $sourceDir $file
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $dest -Force
        }
    }
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
        if ($status -or $cosmosSkew) { return "$head+dirty" }
        return "$head"
    } catch {
        return 'unknown'
    }
}

# The release tag, such as v0.10.0, of a clean checkout of exactly that tag; '' for any other build.
function Get-ReleaseTag([string] $BuildId) {
    if ($BuildId -match '\+dirty$|^unknown$') { return '' }
    # tag --points-at prints nothing for an untagged HEAD; git describe --exact-match writes its
    # "no tag" message to stderr, which Windows PowerShell 5.1 turns into a terminating error. A real
    # git failure still fails.
    $tags = @(& git tag --points-at HEAD)
    if ($LASTEXITCODE -ne 0) { throw "git tag --points-at HEAD failed with exit code $LASTEXITCODE." }
    if ($tags.Count -eq 0) { return '' }
    return $tags[0].Trim()
}

# Library packages expose API that tests and later features use, so only application code
# is held to the unused-procedure check.
$appFlags = @($flags | Where-Object { $_ -notlike '-vet-packages:*' }) +
    @('-vet-packages:main', '-vet-unused-procedures')

# The style rules apply to hand-written application code; generated bindings mirror their foreign
# sources. Tests and tools are not gated yet; they carry the same drift and a separate pass owns it.
function Invoke-AppStyleCheck {
    Build-StyleCheck 'build/stylecheck.exe' $flags
    Invoke-StyleCheck 'build/stylecheck.exe' @('ghostty', 'lua')
}

switch ($Task) {
    'verify' {
        # Its aio.exe also trusts the headless build, so scripts that call build\aio.exe work with both.
        Build-App @('-debug', '-subsystem:console', '-define:AIO_CONTROL=true') 'build/aiodev-verify.exe' `
            'headless/aiodev-headless.exe'
        # The same harness with the headless backend (WORK-349), in its own directory so its aio.exe
        # names it as the server.
        New-Item -ItemType Directory -Force build/headless | Out-Null
        Build-App @('-debug', '-subsystem:console', '-define:AIO_CONTROL=true', '-define:COSMOS_HEADLESS=true') `
            'build/headless/aiodev-headless.exe'
        foreach ($name in $toolPackages) {
            Invoke-Odin build "tools/$name" "-out:build/$name.exe" -debug '-subsystem:console' @flags
        }
    }
    'debug' { Build-App @('-debug', '-subsystem:console') }
    'types' {
        # types/aio.lua is the aio API's built-in definitions for lua-language-server; a test compares it
        # with what the app generates, so regenerate it whenever a command, event or reply changes.
        Build-App @('-debug', '-subsystem:console')
        New-Item -ItemType Directory -Force types | Out-Null
        & build/aiodev.exe --lua-types types/aio.lua
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Write-Output 'Types: types/aio.lua'
    }
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
        Copy-Item -LiteralPath 'tools/uninstall.ps1' -Destination "$stage/uninstall.ps1"
        Copy-Item -LiteralPath 'tools/update.ps1' -Destination "$stage/update.ps1"
        Copy-Item -LiteralPath 'LICENSE' -Destination "$stage/LICENSE.txt"
        Copy-Item -LiteralPath 'THIRD_PARTY_NOTICES.txt' -Destination "$stage/THIRD_PARTY_NOTICES.txt"
        Copy-Conpty $stage
        Copy-Item -LiteralPath "$cosmosRoot/themes" -Destination $stage -Recurse -Force
        Copy-Item -LiteralPath 'nvim' -Destination $stage -Recurse -Force
        Copy-PSVim $stage
        # The aio API's definitions for lua-language-server ship beside aio.exe as types\aio.lua.
        New-Item -ItemType Directory -Force "$stage/types" | Out-Null
        Copy-Item -LiteralPath 'types/aio.lua' -Destination "$stage/types/aio.lua"
        [IO.File]::WriteAllText((Join-Path $PWD "$stage/build.txt"), "$buildId`r`n")
        # install.ps1 installs exactly what this list names, so the stage above is the one file list.
        $stageRoot = (Resolve-Path -LiteralPath $stage).Path
        $manifest = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File |
            ForEach-Object { $_.FullName.Substring($stageRoot.Length + 1) } |
            Where-Object { $_ -ne 'install.ps1' } | Sort-Object)
        [IO.File]::WriteAllText((Join-Path $stageRoot 'files.txt'), (($manifest | ForEach-Object { "$_`r`n" }) -join ''))
        # A clean checkout of a release tag names the archive after the tag; anything else uses the revision.
        $label = Get-ReleaseTag $buildId
        if (-not $label) { $label = $buildId }
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
        Invoke-AppStyleCheck
        foreach ($name in $sourcePackages) {
            Invoke-Odin check "src/$name" -no-entry-point @flags
        }
        if (Get-ChildItem src -Filter *.odin -File) {
            Invoke-Odin check src @flags
            Invoke-Odin check src @appFlags
            Invoke-Odin check src '-define:AIO_CONTROL=true' @appFlags
            Invoke-Odin check src '-define:COSMOS_HEADLESS=true' @appFlags
            Invoke-Odin check src '-define:COSMOS_HEADLESS=true' '-define:AIO_CONTROL=true' @appFlags
        }
        foreach ($name in $toolPackages) {
            Invoke-Odin check "tools/$name" @flags
        }
    }
    'test' {
        . "$PSScriptRoot/tools/test-suite.ps1"
        Invoke-TestSuite -TestPackages $testPackages -Package $Package -TestNames $TestNames `
            -TestLane $TestLane -TestTimeoutSeconds $TestTimeoutSeconds -Flags $flags -Resource $resource `
            -CosmosRoot $cosmosRoot
    }
}
