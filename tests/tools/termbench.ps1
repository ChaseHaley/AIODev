[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'tests/live/termbench_common.ps1')

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Test-SettingsParser([string] $SettingsPath, [string] $Command, [string] $Directory,
    [string] $Groups) {
    $legacyPath = Join-Path $data 'legacy.ini'
    $commandPath = Join-Path $data 'command.txt'
    $directoryPath = Join-Path $data 'directory.txt'
    $groupsPath = Join-Path $data 'groups.txt'
    [IO.File]::WriteAllText($legacyPath, 'shell.command = ' + $Command)
    [IO.File]::WriteAllText($commandPath, $Command)
    [IO.File]::WriteAllText($directoryPath, $Directory)
    [IO.File]::WriteAllText($groupsPath, $Groups)
    & $settingsParser $legacyPath $SettingsPath $commandPath $directoryPath $groupsPath
    Assert-True ($LASTEXITCODE -eq 0) 'Product settings parser regression failed'
}

function Test-Cohort([string] $Name, [hashtable] $Overrides, [string] $ExpectedFailure,
    [int] $Starts, [int] $Cleanups) {
    $scenario = @{
        time = 0.0; launches = 0; starts = 0; cleanups = 0; probes = 0; states = 0
        summaries = 0; receipts = [Collections.Generic.List[object]]::new()
        events = [Collections.Generic.List[object]]::new()
    }
    $actions = @{
        Now = { $scenario.time }
        Sleep = { $scenario.time += 0.3 }
        Launch = { $scenario.launches++; [pscustomobject]@{ Id = 42 } }
        State = {
            param($owner)
            Assert-True ($owner.Id -eq 42) 'State received unrelated process.'
            $scenario.states++
            [pscustomobject]@{ Ready = $true; Exited = $false
                Done = $scenario.starts -eq 1; Failure = '' }
        }
        Probe = {
            param($owner)
            Assert-True ($owner.Id -eq 42) 'Probe received unrelated process.'
            $scenario.probes++
            [pscustomobject]@{ Valid = $true; Detail = 'foreground=99 hits=9/9' }
        }
        Start = { param($owner) $scenario.starts++ }
        Summaries = { $scenario.summaries++; 'qualified summaries' }
        Cleanup = {
            param($owner)
            Assert-True ($owner.Id -eq 42) 'Cleanup received unrelated process.'
            $scenario.cleanups++
        }
        Event = { param($phase, $probe) $scenario.events.Add(@{ phase = $phase; valid = $probe.Valid }) }
        Receipt = {
            param($status, $phase, $failure, $started)
            $scenario.receipts.Add(@{ status = $status; phase = $phase; failure = $failure; started = $started })
        }
    }
    foreach ($key in $Overrides.Keys) { $actions[$key] = $Overrides[$key] }
    $message = ''
    $output = @()
    try { $output = @(Invoke-TermBenchCohort $actions 1 1 1) }
    catch { $message = $_.Exception.Message }
    $final = $scenario.receipts[$scenario.receipts.Count - 1]
    Assert-True ($scenario.launches -eq 1) "$Name launch count"
    Assert-True ($scenario.starts -eq $Starts) "$Name benchmark start count"
    Assert-True ($scenario.cleanups -eq $Cleanups) "$Name cleanup count"
    Assert-True ($scenario.receipts[0].status -eq 'invalid') "$Name optimistic initial receipt"
    if ($ExpectedFailure) {
        Assert-True ($message -like "*$ExpectedFailure*") "$Name expected '$ExpectedFailure', got '$message'"
        Assert-True ($output.Count -eq 0) "$Name leaked successful summaries"
        Assert-True ($final.status -eq 'invalid') "$Name accepted a failure"
        Assert-True ($final.failure -like "*$ExpectedFailure*") "$Name missing failure receipt"
    } else {
        Assert-True (-not $message) "$Name unexpected failure: $message"
        Assert-True ($final.status -eq 'accepted') "$Name rejected success"
        Assert-True ($scenario.summaries -eq 1 -and $output[0] -eq 'qualified summaries') "$Name summaries"
        Assert-True ($scenario.events.Count -eq 2) "$Name must probe admission and done observation"
    }
    Assert-True ($final.started -eq ($Starts -eq 1)) "$Name start receipt"
    Write-Output "PASS $Name starts=$($scenario.starts) cleanup=$($scenario.cleanups) status=$($final.status)"
}

Test-Cohort 'admission refusal never starts benchmark' @{
    Probe = { $scenario.probes++; [pscustomobject]@{ Valid = $false; Detail = 'hits=8/9' } }
} 'Display admission timed out' 0 1

Test-Cohort 'admitted cohort accepts after final probe and cleanup' @{} '' 1 1

Test-Cohort 'slow admission probe cannot start past deadline' @{
    Probe = {
        $scenario.time += 2
        [pscustomobject]@{ Valid = $true; Detail = 'late probe' }
    }
} 'Display admission timed out' 0 1

Test-Cohort 'slow final probe cannot accept past deadline' @{
    Probe = {
        if ($scenario.starts) { $scenario.time += 2 }
        [pscustomobject]@{ Valid = $true; Detail = 'late completion probe' }
    }
} 'TermBench timed out' 1 1

Test-Cohort 'delayed admission starts once' @{
    Probe = {
        $scenario.probes++
        [pscustomobject]@{ Valid = $scenario.probes -gt 1; Detail = 'delayed' }
    }
    Event = {
        param($phase, $probe)
        if ($probe.Valid) { $scenario.events.Add(@{ phase = $phase; valid = $true }) }
    }
} '' 1 1

Test-Cohort 'condition loss rejects even completed child' @{
    Probe = {
        $scenario.probes++
        [pscustomobject]@{ Valid = $scenario.probes -eq 1; Detail = 'desktop=Winlogon' }
    }
} 'Display condition lost' 1 1

Test-Cohort 'completion timeout cleans cohort' @{
    State = { [pscustomobject]@{ Ready = $true; Exited = $false; Done = $false; Failure = '' } }
} 'TermBench timed out' 1 1

Test-Cohort 'startup timeout cleans partial startup' @{
    State = { [pscustomobject]@{ Ready = $false; Exited = $false; Done = $false; Failure = '' } }
} 'Startup timed out' 0 1

Test-Cohort 'launch failure retains invalid receipt without unknown cleanup' @{
    Launch = { $scenario.launches++; throw 'CreateProcess failed' }
} 'CreateProcess failed' 0 0

Test-Cohort 'early process exit cleans only owned process' @{
    State = { [pscustomobject]@{ Ready = $false; Exited = $true; Done = $false; Failure = '' } }
} 'AIODev exited' 0 1

Test-Cohort 'child failure overrides done marker' @{
    State = {
        [pscustomobject]@{ Ready = $true; Exited = $false; Done = $true
            Failure = $(if ($scenario.starts) { 'TermBench failed: 7' } else { '' }) }
    }
} 'TermBench failed: 7' 1 1

Test-Cohort 'probe error never starts benchmark' @{
    Probe = { throw 'OpenInputDesktop failed' }
} 'OpenInputDesktop failed' 0 1

Test-Cohort 'cancellation invalidates and cleans' @{
    Sleep = { throw [OperationCanceledException]::new('test cancellation') }
    State = { [pscustomobject]@{ Ready = $true; Exited = $false; Done = $false; Failure = '' } }
} 'test cancellation' 1 1

Test-Cohort 'cleanup failure suppresses successful summaries' @{
    Cleanup = { $scenario.cleanups++; throw 'owned job cleanup timed out' }
} 'Cleanup failed' 1 1

Test-Cohort 'malformed summaries cannot accept' @{
    Summaries = { throw 'Missing summary in run 1.' }
} 'Missing summary' 1 1

$data = Join-Path $repo ('build/termbench-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $data | Out-Null
$receiptData = $null
try {
    $settingsParser = Join-Path $data 'settings-parser.exe'
    & odin build (Join-Path $PSScriptRoot 'termbench_settings.odin') -file "-out:$settingsParser" `
        "-collection:aio=$(Join-Path $repo 'src')" -vet -vet-cast -vet-tabs -vet-using-param `
        -vet-unused-procedures -vet-packages:termbench_settings -strict-style -warnings-as-errors -disallow-do
    Assert-True ($LASTEXITCODE -eq 0) 'Headless product settings parser fixture did not compile'
    $reproducedCommand = '"C:\Program Files\WindowsApps\' +
        'Microsoft.PowerShell_7.6.7.0_x64__8wekyb3d8bbwe\pwsh.exe"' +
        ' -NoLogo -NoProfile -ExecutionPolicy Bypass -File' +
        ' "C:\Users\chale\Projects\AIODev\build\work148-candidate\tests\live\termbench.ps1"' +
        ' -Label w148-control-1021 -Runs 3 -Benchmark' +
        ' "C:\Users\chale\Libraries\termbench\termbench_release_msvc.exe"' +
        ' -Token 888114049bcd4a4582572128b09aad81 -StartupSeconds 15 -AdmissionSeconds 30 -Child'
    $settingsPath = Join-Path $data 'strings.ini'
    foreach ($directory in @('C:\repo with spaces\', ' "C:\quoted\#hash=equals\" ', '\\server\share with spaces\')) {
        [IO.File]::WriteAllLines($settingsPath, @(
            ('shell.command = ' + (ConvertTo-TermBenchSettingString $reproducedCommand))
            ('shell.directory = ' + (ConvertTo-TermBenchSettingString $directory))
            ('process.padding_groups = ' + (ConvertTo-TermBenchSettingString ''))
        ))
        Test-SettingsParser $settingsPath $reproducedCommand $directory ''
    }
    Write-Output 'PASS product parser reproduces old command diagnostic and round-trips literal quotes/backslashes/whitespace/UNC'
    foreach ($invalid in @("bad`nwindow.rows = 1", "bad`rvalue", "bad$([char]0)value")) {
        $message = ''
        try { ConvertTo-TermBenchSettingString $invalid | Out-Null } catch { $message = $_.Exception.Message }
        Assert-True ($message -like '*NUL or line breaks*') 'Settings serializer accepted an unrepresentable value'
    }
    Write-Output 'PASS settings serializer refuses NUL and line injection'

    $signalData = Join-Path $data 'signals'
    New-Item -ItemType Directory -Path $signalData | Out-Null
    $signalToken = [Guid]::NewGuid().ToString('N')
    $signalOwner = [pscustomobject]@{ HasExited = $false }
    $pending = Join-Path $signalData 'ready.txt.pending.tmp'
    $writer = [IO.File]::Open($pending, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $writer.WriteByte(97)
        $writer.Flush()
        $state = Read-TermBenchState $signalOwner $signalData $signalToken
        Assert-True (-not $state.Ready -and -not $state.Done -and -not $state.Failure) 'Unpublished locked file became visible'
    } finally {
        $writer.Dispose()
        [IO.File]::Delete($pending)
    }
    Write-Output 'PASS real signal reader ignores an incomplete locked temporary file'

    Write-TermBenchSignal (Join-Path $signalData 'ready.txt') 'wrong-token'
    Test-Cohort 'real ready-token mismatch prevents admission' @{
        State = { Read-TermBenchState $signalOwner $signalData $signalToken }
    } 'Invalid ready token' 0 1
    [IO.File]::Delete((Join-Path $signalData 'ready.txt'))
    Write-TermBenchSignal (Join-Path $signalData 'ready.txt') $signalToken
    Write-TermBenchSignal (Join-Path $signalData 'done.txt') 'wrong-token'
    Test-Cohort 'real done-token mismatch prevents admission' @{
        State = { Read-TermBenchState $signalOwner $signalData $signalToken }
    } 'Invalid done token' 0 1
    [IO.File]::Delete((Join-Path $signalData 'done.txt'))

    Write-TermBenchSignal (Join-Path $signalData 'start.txt') $signalToken
    Assert-True ([IO.File]::ReadAllText((Join-Path $signalData 'start.txt')) -eq $signalToken) 'Published start token incomplete'
    Write-TermBenchSignal (Join-Path $signalData 'done.txt') $signalToken
    $state = Read-TermBenchState $signalOwner $signalData $signalToken
    Assert-True ($state.Ready -and $state.Done -and -not $state.Failure) 'Published matching signals rejected'
    Write-TermBenchSignal (Join-Path $signalData 'child-failure.txt') 'fixture failure'
    Test-Cohort 'real child failure overrides published completion' @{
        State = { Read-TermBenchState $signalOwner $signalData $signalToken }
    } 'fixture failure' 0 1

    $message = ''
    try { Write-TermBenchSignal (Join-Path $signalData 'start.txt') 'overwrite' }
    catch { $message = $_.Exception.Message }
    Assert-True ([bool]$message) 'Signal publication overwrote an existing handshake'
    Assert-True ([IO.File]::ReadAllText((Join-Path $signalData 'start.txt')) -eq $signalToken) 'Existing signal changed'
    Assert-True (@(Get-ChildItem -LiteralPath $signalData -Filter '*.tmp').Count -eq 0) 'Signal publication leaked temporary files'
    Write-Output 'PASS actual signal publication is complete, refuses overwrite, and cleans failed temporary writes'


    $names = @('ManyLine', 'LongLine', 'FGPerChar', 'FGBGPerChar', 'TermMarkV2 Normal')
    $lines = @($names | ForEach-Object { "${_}: 1.23s (4.56gb/s)" })
    [IO.File]::WriteAllText((Join-Path $data 'run-1.txt'), ($lines -join "`n"))
    Assert-True (@(Read-TermBenchSummaries $data 1).Count -eq 6) 'Valid summary rejected'
    $lines[4] = $lines[0]
    [IO.File]::WriteAllText((Join-Path $data 'run-1.txt'), ($lines -join "`n"))
    $message = ''
    try { Read-TermBenchSummaries $data 1 | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -like '*Missing or duplicate*') 'Duplicate metric replaced missing metric'
    Write-Output 'PASS actual summary parser rejects five matches with duplicate/missing metric'

    Add-Type -Path (Join-Path $repo 'tests/live/termbench_windows.cs')
    Write-Output 'PASS native helper compiles (display gate qualification remains unrun)'
    try {
        $probe = [TermBenchDisplay]::Probe(0)
        Assert-True (-not $probe.Valid) 'Read-only probe admitted an unowned window'
        Write-Output 'PASS real read-only probe refuses absent owned window (no display qualification)'
    } catch [System.Management.Automation.MethodInvocationException] {
        $nativeError = $_.Exception.GetBaseException()
        if ($nativeError -isnot [ComponentModel.Win32Exception]) { throw }
        Write-Output ('UNRUN native display qualification; read-only probe fails closed: ' + $nativeError.Message)
    }
    $shell = (Get-Process -Id $PID).Path
    $descendantPath = Join-Path $data 'descendant.txt'
    $script = '$child = Start-Process -FilePath ' + "'$shell'" +
        ' -ArgumentList ''-NoLogo -NoProfile -Command "Start-Sleep -Seconds 60"'' -WindowStyle Hidden -PassThru; ' +
        '[IO.File]::WriteAllText(' + "'$descendantPath'" + ', [string]$child.Id); Start-Sleep -Seconds 60'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $owner = $null
    $descendant = $null
    $root = $null
    $unrelated = Start-Process -FilePath $shell -ArgumentList '-NoLogo -NoProfile -Command "Start-Sleep -Seconds 60"' `
        -WindowStyle Hidden -PassThru
    try {
        $owner = [TermBenchProcess]::Launch($shell, "-NoLogo -NoProfile -EncodedCommand $encoded", $repo)
        $limit = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $descendantPath)) {
            if ($owner.HasExited -or $limit.Elapsed.TotalSeconds -ge 10) { throw 'Headless child did not start' }
            Start-Sleep -Milliseconds 50
        }
        $descendant = Get-Process -Id ([int][IO.File]::ReadAllText($descendantPath))
        $root = Get-Process -Id $owner.Id
        $owner.Dispose()
        Assert-True ($root.WaitForExit(5000)) 'Owned root survived cleanup'
        Assert-True ($descendant.WaitForExit(5000)) 'Owned descendant survived cleanup'
        Assert-True (-not $unrelated.HasExited) 'Cleanup terminated an unrelated process'
        $owner.Dispose()
        Write-Output 'PASS real hidden job cleans root/descendant, preserves unrelated process, and is idempotent'
    } finally {
        if ($owner) { $owner.Dispose() }
        if ($root) { $root.Dispose() }
        if ($descendant) { $descendant.Dispose() }
        if (-not $unrelated.HasExited) {
            $unrelated.Kill()
            Assert-True ($unrelated.WaitForExit(5000)) 'Unrelated test fixture cleanup timed out'
        }
        $unrelated.Dispose()
    }
    $message = ''
    try { [TermBenchProcess]::Launch((Join-Path $data 'missing.exe'), '', $repo) | Out-Null }
    catch { $message = $_.Exception.GetBaseException().Message }
    Assert-True ($message -like '*CreateProcess*') 'Failed startup was not reported'
    Write-Output 'PASS real failed process startup reports error and disposes partial ownership'

    $label = 'w129-' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $runnerRepo = Join-Path $data 'runner with spaces'
    $runnerScripts = Join-Path $runnerRepo 'tests/live'
    New-Item -ItemType Directory -Path $runnerScripts -Force | Out-Null
    foreach ($name in @('termbench.ps1', 'termbench_common.ps1', 'termbench_windows.cs')) {
        Copy-Item -LiteralPath (Join-Path $repo "tests/live/$name") -Destination $runnerScripts
    }
    $runnerPath = Join-Path $runnerScripts 'termbench.ps1'
    $benchmarkPath = Join-Path $data 'benchmark with spaces.exe'
    [IO.File]::WriteAllText($benchmarkPath, 'Never executed: app launch must fail first.')
    $groups = 'tools:4:pwsh,powershell; editors:0:nvim,vim'
    $receiptData = Join-Path $runnerRepo "build/termbench/$label"
    $message = ''
    try {
        & $runnerPath -Label $label -Runs 1 -Benchmark $benchmarkPath -ProcessGroups $groups `
            -Executable (Join-Path $data 'missing.exe')
    } catch { $message = $_.Exception.Message }
    $receipt = Get-Content -LiteralPath (Join-Path $receiptData 'receipt.json') -Raw | ConvertFrom-Json
    Assert-True ($message -like '*CreateProcess*') 'Actual runner entry did not report launch failure'
    Assert-True ($receipt.status -eq 'invalid' -and -not $receipt.started) 'Actual runner accepted failed startup'
    Assert-True ($receipt.arguments -like '--no-activate *') 'Actual launch omitted --no-activate'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $receiptData 'start.txt'))) 'Failed startup admitted child'
    Write-Output "PASS actual runner validates invalid startup receipt and --no-activate arguments (fixture cleaned on exit): $receiptData"
    Assert-True ($receipt.shell -eq $shell) 'Runner changed the current PowerShell host'
    $expectedCommand = ('"{0}" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{1}"' +
        ' -Label {2} -Runs 1 -Benchmark "{3}" -Token {4}' +
        ' -StartupSeconds 15 -AdmissionSeconds 30 -Child') -f `
            $shell, $runnerPath, $label, $benchmarkPath, $receipt.token
    Test-SettingsParser (Join-Path $receiptData 'settings.ini') $expectedCommand $runnerRepo $groups
    Write-Output 'PASS actual runner settings round-trip through product parser with same host, spaced paths, arguments and token'
} finally {
    $buildRoot = [IO.Path]::GetFullPath((Join-Path $repo 'build')) + [IO.Path]::DirectorySeparatorChar
    $resolvedData = [IO.Path]::GetFullPath($data)
    Assert-True ($resolvedData.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) `
        'Test cleanup path escaped build'
    Remove-Item -LiteralPath $resolvedData -Recurse -Force
    if ($receiptData -and (Test-Path -LiteralPath $receiptData)) {
        $resolvedReceipt = [IO.Path]::GetFullPath($receiptData)
        Assert-True ($resolvedReceipt.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) 'Receipt cleanup path escaped build'
        Remove-Item -LiteralPath $resolvedReceipt -Recurse -Force
    }
}
