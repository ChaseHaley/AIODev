function Invoke-TestSuite {
    param(
        [string[]] $TestPackages,
        [string] $Package,
        [string] $TestNames,
        [string] $TestLane = 'All',
        [int] $TestTimeoutSeconds,
        [string[]] $Flags,
        [string[]] $Resource
    )
    . "$PSScriptRoot/test-budget.ps1"
    . "$PSScriptRoot/test-lanes.ps1"
    $budget = Enter-TestBudget
    try {
        # The pure entry point compiles the suites it imports; don't run them twice in full runs.
        $grouped = @(Select-String -LiteralPath tests/pure/pure_test.odin -Pattern '^@\(require\) import "\.\./(\w+)"' |
            ForEach-Object { $_.Matches[0].Groups[1].Value })
        if ($grouped.Count -eq 0) { throw 'tests/pure/pure_test.odin imports no suites.' }
        $targets = if ($Package) { @($Package) } else { @($testPackages | Where-Object { $_ -notin $grouped }) }
        if ($targets.Count -eq 0) { throw 'No test packages found under tests/.' }
        foreach ($name in $targets) {
            if ($name -notin $testPackages) { throw "No test package named $name." }
        }
        Build-NativeLibraries
        New-Item -ItemType Directory -Force build/test | Out-Null
        Copy-Conpty 'build/test'
        if ('app' -in $targets -and $TestLane -ne 'Fast') {
            $code = Invoke-TestCommand (Get-Command odin -CommandType Application | Select-Object -First 1).Source @(
                'build', 'tests/tools/idle_shell', '-out:build/test/idle-shell.exe', '-thread-count:2',
                '-subsystem:console', '-vet', '-strict-style', '-warnings-as-errors') $TestTimeoutSeconds
            if ($code -ne 0) { throw 'Cannot build the idle shell fixture.' }
        }
        # Run every package so one failure does not hide the state of the rest.
        $failed = @()
        foreach ($name in $targets) {
            $runName = $name
            $selectedNames = $TestNames
            $expected = @()
            if ($name -eq 'app') {
                $inventory = @(Get-AppTestInventory (Get-Location).Path)
                $manifest = Get-Content -LiteralPath tests/app/lanes.json -Raw | ConvertFrom-Json
                $expected = @(Select-AppTests $inventory $manifest.fast $TestLane $TestNames)
                if ($TestLane -ne 'All') {
                    $runName = "app-$($TestLane.ToLowerInvariant())"
                    $selectedNames = $expected -join ','
                }
                Write-Host "App lane ${TestLane}: $($expected.Count)/$($inventory.Count) tests. Unclassified tests are native."
            }
            $reportPath = "build/test/$runName.json"
            Remove-Item -LiteralPath $reportPath -ErrorAction SilentlyContinue
            [string[]] $testDefines = @()
            if ($name -eq 'app') { $testDefines = @('-define:AIO_CONTROL=true', '-define:AIO_TEST_COSTS=true') }
            if ($name -eq 'pure') { $testDefines += '-all-packages' }
            if ($selectedNames) { $testDefines += "-define:ODIN_TEST_NAMES=$selectedNames" }
            $testArgs = @('test', "tests/$name", "-out:build/test/$name.exe", '-debug', '-keep-executable',
                '-thread-count:2', '-define:ODIN_TEST_THREADS=1', '-define:ODIN_TEST_FANCY=false',
                '-define:ODIN_TEST_LOG_STATE_CHANGES=true',
                "-define:ODIN_TEST_JSON_REPORT=$reportPath") +
                $flags + $resource + $testDefines
            $code = Invoke-TestCommand (Get-Command odin -CommandType Application | Select-Object -First 1).Source `
                $testArgs $TestTimeoutSeconds "build/test/$runName.output.log"
            # Odin reports unknown selectors but still exits successfully, even with zero tests.
            if ($code -eq 0 -and ($selectedNames -or $name -eq 'app')) {
                $ran = @()
                if (Test-Path -LiteralPath $reportPath) {
                    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
                    $ran = foreach ($entry in $report.packages.PSObject.Properties) {
                        foreach ($result in $entry.Value) { $result.name; "$($entry.Name).$($result.name)" }
                    }
                }
                $required = if ($name -eq 'app') { $expected } else { $selectedNames.Split(',') }
                $missing = @($required | Where-Object { $_ -notin $ran })
                if ($missing) {
                    Write-Host "Requested tests did not run: $($missing -join ', ')"
                    $code = 1
                }
                if ($name -eq 'app') {
                    $actual = @($report.packages.app_test | ForEach-Object name)
                    $extra = @($actual | Where-Object { $_ -notin $expected })
                    if ($extra -or $actual.Count -ne $expected.Count) {
                        Write-Host 'App test receipt does not match the exact lane selection.'
                        $code = 1
                    }
                    @{ Lane = $TestLane; Expected = $expected; Actual = $actual; Inventory = $inventory.Count } |
                        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "build/test/$runName.selection.json" -Encoding utf8
                }
            }
            if ($code -ne 0) { $failed += $name }
        }
        if ($failed) {
            Write-Output "Failed test packages: $($failed -join ', ')"
            exit 1
        }
    } finally {
        Exit-TestBudget $budget
    }
}
