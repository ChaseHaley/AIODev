function Invoke-TestSuite {
    param(
        [string[]] $TestPackages,
        [string] $Package,
        [string] $TestNames,
        [int] $TestTimeoutSeconds,
        [string[]] $Flags,
        [string[]] $Resource
    )
    . "$PSScriptRoot/test-budget.ps1"
    $budget = Enter-TestBudget
    try {
        # The pure entry point compiles these suites together; don't run them twice in full runs.
        $grouped = @('colour', 'draws', 'fuzzy', 'perf', 'pixels', 'program_art', 'vector')
        $targets = if ($Package) { @($Package) } else { @($testPackages | Where-Object { $_ -notin $grouped }) }
        if ($targets.Count -eq 0) { throw 'No test packages found under tests/.' }
        foreach ($name in $targets) {
            if ($name -notin $testPackages) { throw "No test package named $name." }
        }
        Build-Notifications
        New-Item -ItemType Directory -Force build/test | Out-Null
        Copy-Conpty 'build/test'
        if ('app' -in $targets) {
            $code = Invoke-TestCommand (Get-Command odin -CommandType Application | Select-Object -First 1).Source @(
                'build', 'tests/tools/idle_shell', '-out:build/test/idle-shell.exe', '-thread-count:2',
                '-subsystem:console', '-vet', '-strict-style', '-warnings-as-errors') $TestTimeoutSeconds
            if ($code -ne 0) { throw 'Cannot build the idle shell fixture.' }
        }
        # Run every package so one failure does not hide the state of the rest.
        $failed = @()
        foreach ($name in $targets) {
            $reportPath = "build/test/$name.json"
            Remove-Item -LiteralPath $reportPath -ErrorAction SilentlyContinue
            [string[]] $testDefines = @()
            if ($name -eq 'app') { $testDefines = @('-define:AIO_CONTROL=true') }
            if ($name -eq 'pure') { $testDefines += '-all-packages' }
            if ($TestNames) { $testDefines += "-define:ODIN_TEST_NAMES=$TestNames" }
            $testArgs = @('test', "tests/$name", "-out:build/test/$name.exe", '-debug', '-keep-executable',
                '-thread-count:2', '-define:ODIN_TEST_THREADS=1', '-define:ODIN_TEST_FANCY=false',
                "-define:ODIN_TEST_JSON_REPORT=$reportPath") +
                $flags + $resource + $testDefines
            $code = Invoke-TestCommand (Get-Command odin -CommandType Application | Select-Object -First 1).Source $testArgs $TestTimeoutSeconds
            # Odin reports unknown selectors but still exits successfully, even with zero tests.
            if ($code -eq 0 -and $TestNames) {
                $ran = @()
                if (Test-Path -LiteralPath $reportPath) {
                    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
                    $ran = foreach ($entry in $report.packages.PSObject.Properties) {
                        foreach ($result in $entry.Value) { $result.name; "$($entry.Name).$($result.name)" }
                    }
                }
                $missing = @($TestNames.Split(',') | Where-Object { $_ -notin $ran })
                if ($missing) {
                    Write-Host "Requested tests did not run: $($missing -join ', ')"
                    $code = 1
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
