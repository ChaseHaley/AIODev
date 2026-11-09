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
            # Each package compiles once. App tests compile twice: headless (WORK-349), and the desktop
            # tests lanes.json lists with the Win32 backend, which opens real windows.
            $runs = @(@{ Name = $name; Selected = $TestNames; Expected = @(); Defines = @() })
            if ($name -eq 'app') {
                $inventory = @(Get-AppTestInventory (Get-Location).Path)
                $manifest = Get-Content -LiteralPath tests/app/lanes.json -Raw | ConvertFrom-Json
                $desktop = @(Get-AppDesktopTests $manifest)
                $expected = @(Select-AppTests $inventory $manifest.fast $TestLane $TestNames $desktop)
                Write-Host "App lane ${TestLane}: $($expected.Count)/$($inventory.Count) tests, $(@($expected |
                    Where-Object { $_ -in $desktop }).Count) on the desktop. Unclassified tests are native."
                $appDefines = @('-define:AIO_CONTROL=true', '-define:AIO_TEST_COSTS=true')
                $headless = @($expected | Where-Object { $_ -notin $desktop })
                $onDesktop = @($expected | Where-Object { $_ -in $desktop })
                $suffix = if ($TestLane -ne 'All') { "-$($TestLane.ToLowerInvariant())" } else { '' }
                # Desktop tests are compiled out of the headless build, so its whole run needs no names.
                $headlessNames = if ($TestLane -ne 'All' -or $TestNames) { $headless -join ',' } else { '' }
                $runs = @()
                if ($headless) {
                    $runs += @{ Name = "app$suffix"; Selected = $headlessNames; Expected = $headless
                        Defines = $appDefines + '-define:AIO_HEADLESS=true' }
                }
                if ($onDesktop) {
                    $runs += @{ Name = "app$suffix-desktop"; Selected = $onDesktop -join ','; Expected = $onDesktop
                        Defines = $appDefines }
                }
            }
            foreach ($run in $runs) {
                $runName = $run.Name
                $selectedNames = $run.Selected
                $expected = $run.Expected
                $reportPath = "build/test/$runName.json"
                Remove-Item -LiteralPath $reportPath -ErrorAction SilentlyContinue
                [string[]] $testDefines = $run.Defines
                if ($name -eq 'pure') { $testDefines += '-all-packages' }
                # The headless suite compiles the app and platform with the headless backend (WORK-349).
                if ($name -eq 'headless') { $testDefines += '-define:AIO_HEADLESS=true' }
                if ($selectedNames) { $testDefines += "-define:ODIN_TEST_NAMES=$selectedNames" }
                $testArgs = @('test', "tests/$name", "-out:build/test/$runName.exe", '-debug', '-keep-executable',
                    '-thread-count:2', '-define:ODIN_TEST_THREADS=1', '-define:ODIN_TEST_FANCY=false',
                    '-define:ODIN_TEST_LOG_STATE_CHANGES=true',
                    "-define:ODIN_TEST_JSON_REPORT=$reportPath") +
                    $flags + $resource + $testDefines
                $code = Invoke-TestCommand (Get-Command odin -CommandType Application | Select-Object -First 1).Source `
                    $testArgs $TestTimeoutSeconds "build/test/$runName.output.log"
                # Odin reports unknown selectors but still exits successfully, even with zero tests.
                if ($code -eq 0 -and ($selectedNames -or $name -eq 'app')) {
                    $ran = @()
                    $report = $null
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
                            if ($extra) { Write-Host "Ran but not selected: $($extra -join ', ')" }
                            $code = 1
                        }
                        @{ Lane = $TestLane; Expected = $expected; Actual = $actual; Inventory = $inventory.Count } |
                            ConvertTo-Json -Depth 4 |
                            Set-Content -LiteralPath "build/test/$runName.selection.json" -Encoding utf8
                    }
                }
                if ($code -ne 0) { $failed += $runName }
            }
        }
        if ($failed) {
            Write-Output "Failed test packages: $($failed -join ', ')"
            exit 1
        }
    } finally {
        Exit-TestBudget $budget
    }
}
