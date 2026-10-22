#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SourceRepository=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$DataDirectory,
    [string]$Compiler
)
$ErrorActionPreference='Stop'
$fixture=Join-Path $PSScriptRoot 'conpty_loader'
if(!$DataDirectory){$DataDirectory=Join-Path $SourceRepository ('build/conpty-loader-'+[guid]::NewGuid().ToString('N'))}
$DataDirectory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DataDirectory)
if(Test-Path -LiteralPath $DataDirectory){throw 'Use a new evidence directory; existing evidence is preserved.'}
if(!$Compiler){
    $Compiler=(Get-Command cl.exe -ErrorAction SilentlyContinue).Source
    if(!$Compiler){$Compiler=Get-ChildItem "$env:ProgramFiles/Microsoft Visual Studio" -Filter cl.exe -Recurse |
        Where-Object{$_.FullName -like '*Hostx64\x64\cl.exe'} | Select-Object -First 1 -ExpandProperty FullName}
}
if(!$Compiler){throw 'The existing x64 MSVC compiler is required for harmless native test fixtures.'}
New-Item -ItemType Directory $DataDirectory | Out-Null
$runner=Join-Path $DataDirectory 'loader-check.exe'
& odin build $fixture "-collection:aio=$SourceRepository/src" "-out:$runner" -subsystem:console -o:speed `
    -vet -vet-cast -vet-tabs -vet-using-param -vet-unused-procedures -vet-packages:conpty_loader `
    -strict-style -warnings-as-errors -disallow-do
if($LASTEXITCODE -ne 0){throw 'Cannot build loader checker.'}
$objects=Join-Path $DataDirectory 'objects'
New-Item -ItemType Directory $objects | Out-Null
$dependency=Join-Path $objects 'aio_work127_dependency.dll'
& $Compiler /nologo /LD /O2 /GS- /W4 /WX "$fixture/dependency.c" "/Fo$objects/dependency.obj" /link /NOENTRY /NODEFAULTLIB `
    "/OUT:$dependency" "/IMPLIB:$objects/dependency.lib"
if($LASTEXITCODE -ne 0){throw 'Cannot build dependency fixture.'}
foreach($variant in @('complete','missing-exports')){
    [string[]]$defines=if($variant -eq 'missing-exports'){@('/DMISSING_EXPORTS')}else{@()}
    & $Compiler /nologo /LD /O2 /GS- /W4 /WX @defines "$fixture/conpty.c" "/Fo$objects/$variant.obj" /link /NOENTRY /NODEFAULTLIB `
        "$objects/dependency.lib" "/OUT:$objects/$variant.dll" "/IMPLIB:$objects/$variant.lib"
    if($LASTEXITCODE -ne 0){throw "Cannot build $variant fixture."}
}
$failures=0
foreach($case in @('trusted-sibling','cwd-only','path-only','missing-dependency','missing-exports','absent-bundle')){
    $caseDir=Join-Path $DataDirectory $case
    $trusted=Join-Path $caseDir 'trusted';$untrusted=Join-Path $caseDir 'untrusted';$neutral=Join-Path $caseDir 'neutral'
    foreach($dir in @($trusted,$untrusted,$neutral)){New-Item -ItemType Directory $dir | Out-Null}
    $exe=Join-Path $trusted 'loader-check.exe'
    Copy-Item -LiteralPath $runner -Destination $exe
    if($case -ne 'absent-bundle'){
        $variant=if($case -eq 'missing-exports'){'missing-exports'}else{'complete'}
        Copy-Item -LiteralPath "$objects/$variant.dll" -Destination "$trusted/conpty.dll"
    }
    if($case -in @('trusted-sibling','missing-exports')){Copy-Item -LiteralPath $dependency -Destination $trusted}
    if($case -in @('trusted-sibling','cwd-only','path-only')){Copy-Item -LiteralPath $dependency -Destination $untrusted}
    $info=[Diagnostics.ProcessStartInfo]::new($exe)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.WorkingDirectory=if($case -in @('trusted-sibling','cwd-only')){$untrusted}else{$neutral}
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    if($case -eq 'path-only'){$info.Environment['PATH']=$untrusted+';'+$info.Environment['PATH']}
    $expected=$case -eq 'trusted-sibling'
    $info.ArgumentList.Add($expected.ToString().ToLowerInvariant())
    $info.ArgumentList.Add($(if($expected){Join-Path $trusted 'aio_work127_dependency.dll'}else{'-'}))
    $child=[Diagnostics.Process]::Start($info)
    try {
        $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
        if(!$child.WaitForExit(15000)){$child.Kill($true);$child.WaitForExit();throw "Loader checker timed out: $case"}
        $out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText("$caseDir/stdout.txt",$out)
        [IO.File]::WriteAllText("$caseDir/stderr.txt",$err)
        "$case pid=$($child.Id) exit=$($child.ExitCode) $($out.Trim())"
        if($child.ExitCode -ne 0){$failures++;"FAIL $case"}else{"PASS $case"}
    } finally {$child.Dispose()}
}
if($failures){throw "$failures loader-policy cases failed; receipts retained at $DataDirectory"}
'PASS all loader check processes exited normally; no app windows or shell sessions launched'
