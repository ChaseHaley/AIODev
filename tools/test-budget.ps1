# Shared by every worktree in the Windows session. Fail fast instead of queuing more suites.
function Enter-TestBudget {
    $lease = [Threading.Mutex]::new($false, 'Local\AIODev.TestBudget.v1')
    $acquired = $false
    $budget = $null
    try {
        try { $acquired = $lease.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            throw 'Another AIODev test run owns the machine test budget. Stop here; run the owed tests after it finishes.'
        }
        $hostProcess = [Diagnostics.Process]::GetCurrentProcess()
        $budget = [pscustomobject]@{
            Lease = $lease
            Process = $hostProcess
            Affinity = $hostProcess.ProcessorAffinity
            Priority = $hostProcess.PriorityClass
        }
        # Children inherit affinity, including ConPTY hosts and shells started by native fixtures.
        $allowed = $budget.Affinity.ToInt64()
        [long] $limited = 0
        $count = 0
        for ($bit = 0; $bit -lt 63 -and $count -lt 2; $bit++) {
            [long] $mask = [long]1 -shl $bit
            if ($allowed -band $mask) { $limited = $limited -bor $mask; $count++ }
        }
        if (-not $limited) { throw 'Cannot establish the test CPU budget.' }
        $hostProcess.ProcessorAffinity = [IntPtr]$limited
        $hostProcess.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal
        Write-Host "Test budget: one run, two CPUs maximum, below-normal priority, serial tests."
        return $budget
    } catch {
        if ($budget) {
            $budget.Process.ProcessorAffinity = $budget.Affinity
            $budget.Process.PriorityClass = $budget.Priority
        }
        if ($acquired) { $lease.ReleaseMutex() }
        $lease.Dispose()
        throw
    }
}

function Exit-TestBudget($Budget) {
    try {
        $Budget.Process.ProcessorAffinity = $Budget.Affinity
        $Budget.Process.PriorityClass = $Budget.Priority
    } finally {
        $Budget.Lease.ReleaseMutex()
        $Budget.Lease.Dispose()
        $Budget.Process.Dispose()
    }
}

function Invoke-TestCommand([string] $Executable, [string[]] $Arguments, [int] $TimeoutSeconds) {
    # Start-Process needs a Windows command line even when ArgumentList receives an array.
    $line = ($Arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
    $child = Start-Process -FilePath $Executable -ArgumentList $line -NoNewWindow -PassThru -ErrorAction Stop
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $child.WaitForExit(200)) {
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                Write-Host "Test command timed out after $TimeoutSeconds seconds; stopping its process tree."
                return 124
            }
        }
        return $child.ExitCode
    } finally {
        # Kill descendants as well when the runner hangs or the invoking shell is cancelled.
        if (-not $child.HasExited) {
            & taskkill.exe /PID $child.Id /T /F | Out-Null
            if (-not $child.WaitForExit(5000)) { throw "Cannot stop owned test process $($child.Id)." }
        }
        $child.Dispose()
    }
}
