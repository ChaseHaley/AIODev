function ConvertTo-TermBenchSettingString {
    param([string] $Value)

    if ($Value.IndexOfAny([char[]]@([char]0, [char]10, [char]13)) -ge 0) {
        throw 'TermBench settings strings cannot contain NUL or line breaks.'
    }
    # settings.assign removes one outer quote pair; it does not decode escapes.
    return '"' + $Value + '"'
}

function Write-TermBenchSignal {
    param([string] $Path, [string] $Value)

    # Publish only a closed complete file; readers never observe the writer's handle.
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Value)
        [IO.File]::Move($temporary, $Path)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Read-TermBenchState {
    param($Owner, [string] $Data, [string] $Token)

    $failurePath = Join-Path $Data 'child-failure.txt'
    $failure = if (Test-Path -LiteralPath $failurePath) { [IO.File]::ReadAllText($failurePath) } else { '' }
    $flags = @{}
    foreach ($name in @('ready', 'done')) {
        $path = Join-Path $Data "$name.txt"
        $flags[$name] = Test-Path -LiteralPath $path
        if ($flags[$name] -and [IO.File]::ReadAllText($path) -ne $Token) {
            $failure = "Invalid $name token."
        }
    }
    [pscustomobject]@{
        Exited = $Owner.HasExited; Ready = $flags.ready; Done = $flags.done; Failure = $failure
    }
}

function Invoke-TermBenchCohort {
    param(
        [hashtable] $Actions,
        [double] $StartupSeconds,
        [double] $AdmissionSeconds,
        [double] $CompletionSeconds
    )

    $owner = $null
    $failure = 'Runner interrupted before acceptance.'
    $phase = 'startup'
    $started = $false
    $summaries = @()
    & $Actions.Receipt 'invalid' $phase $failure $started
    try {
        $deadline = (& $Actions.Now) + $StartupSeconds
        $owner = & $Actions.Launch
        & $Actions.Receipt 'invalid' $phase 'Awaiting child readiness.' $started
        while ($true) {
            $state = & $Actions.State $owner
            if ($state.Failure) { throw "Child failed: $($state.Failure)" }
            if ($state.Exited) { throw 'AIODev exited before completion.' }
            if ((& $Actions.Now) -ge $deadline) { throw 'Startup timed out.' }
            if ($state.Ready) { break }
            & $Actions.Sleep
        }

        $phase = 'admission'
        & $Actions.Receipt 'invalid' $phase 'Awaiting read-only display admission.' $started
        $deadline = (& $Actions.Now) + $AdmissionSeconds
        while ($true) {
            $state = & $Actions.State $owner
            if ($state.Failure) { throw "Child failed: $($state.Failure)" }
            if ($state.Exited) { throw 'AIODev exited before admission.' }
            if ((& $Actions.Now) -ge $deadline) { throw 'Display admission timed out; benchmark not started.' }
            $probe = & $Actions.Probe $owner
            & $Actions.Event $phase $probe
            if ((& $Actions.Now) -ge $deadline) { throw 'Display admission timed out; benchmark not started.' }
            if ($probe.Valid) { break }
            & $Actions.Sleep
        }

        & $Actions.Start $owner
        $started = $true
        $phase = 'running'
        & $Actions.Receipt 'invalid' $phase 'Runner interrupted before acceptance.' $started
        $deadline = (& $Actions.Now) + $CompletionSeconds
        while ($true) {
            $state = & $Actions.State $owner
            if ($state.Failure) { throw "Child failed: $($state.Failure)" }
            if ($state.Exited) { throw 'AIODev exited before completion.' }
            if ((& $Actions.Now) -ge $deadline) { throw 'TermBench timed out.' }
            $probe = & $Actions.Probe $owner
            & $Actions.Event $phase $probe
            if (-not $probe.Valid) { throw "Display condition lost; cohort invalid: $($probe.Detail)" }
            if ((& $Actions.Now) -ge $deadline) { throw 'TermBench timed out.' }
            # Probe the completion observation too; done.txt alone never qualifies a cohort.
            if ($state.Done) { break }
            & $Actions.Sleep
        }
        $phase = 'summaries'
        $summaries = @(& $Actions.Summaries)
        $failure = ''
    } catch {
        $failure = $_.Exception.Message
    } finally {
        try {
            if ($null -ne $owner) { & $Actions.Cleanup $owner }
        } catch {
            $failure = "$failure Cleanup failed: $($_.Exception.Message)".Trim()
        }
        $status = if ($failure) { 'invalid' } else { 'accepted' }
        & $Actions.Receipt $status $phase $failure $started
    }
    if ($failure) { throw $failure }
    $summaries
}

function Read-TermBenchSummaries {
    param([string] $Data, [int] $Runs)

    $output = @()
    $names = @('ManyLine', 'LongLine', 'FGPerChar', 'FGBGPerChar', 'TermMarkV2 Normal')
    foreach ($i in 1..$Runs) {
        $screen = [IO.File]::ReadAllText((Join-Path $Data "run-$i.txt"))
        $results = [regex]::Matches($screen,
            '(?<![A-Za-z])(?<name>ManyLine|LongLine|FGPerChar|FGBGPerChar|TermMarkV2 Normal): ' +
            '[0-9]+(?:\.[0-9]+)?s \([0-9]+(?:\.[0-9]+)?gb/s\)')
        if ($results.Count -ne 5) { throw "Missing or duplicate summary in run $i." }
        foreach ($name in $names) {
            if (@($results | Where-Object { $_.Groups['name'].Value -eq $name }).Count -ne 1) {
                throw "Missing or duplicate $name summary in run $i."
            }
        }
        $output += "Run $i"
        $output += $results | ForEach-Object Value
    }
    $output
}
