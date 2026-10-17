[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('debug', 'release', 'run', 'test', 'check')]
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
$vetPackages = @('main') + $sourcePackages + ($testPackages | ForEach-Object { "${_}_test" })

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

function Build-App([string[]] $Mode) {
    Invoke-Odin build src '-out:build/aiodev.exe' @Mode @flags @resource
}

# Library packages expose API that tests and later features use, so only application code
# is held to the unused-procedure check.
$appFlags = @($flags | Where-Object { $_ -notlike '-vet-packages:*' }) + @('-vet-packages:main', '-vet-unused-procedures')

switch ($Task) {
    'debug' { Build-App @('-debug', '-subsystem:console') }
    'release' { Build-App @('-o:speed', '-subsystem:windows') }
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
        }
    }
    'test' {
        $targets = if ($Package) { @($Package) } else { $testPackages }
        if ($targets.Count -eq 0) { throw 'No test packages found under tests/.' }
        New-Item -ItemType Directory -Force build/test | Out-Null
        foreach ($name in $targets) {
            if (-not (Test-Path "tests/$name")) { throw "No tests at tests/$name." }
            Invoke-Odin test "tests/$name" "-out:build/test/$name.exe" -debug -keep-executable @flags
        }
    }
}
