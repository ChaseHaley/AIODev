[CmdletBinding()]
param(
    [string] $Program = 'claude',
    [ValidateRange(1, 20)] [int] $Samples = 3,
    [ValidateRange(1, 10000)] [int] $LimitMs = 250
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'pane-close-latency'
$data = Join-Path $repo "build/verify/$name"
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    return $out
}
function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Aio state)) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1]
    }
    return $state
}
$measurements = @()
try {
    Invoke-Aio launch --fresh | Write-Output
    Invoke-Aio doctor | Write-Output
    # Bind a key in this isolated instance to exercise the same pane action as the header.
    [IO.File]::AppendAllText((Join-Path $data 'settings.ini'), "`nkeys.pane.close = Ctrl+Alt+W`n")
    Invoke-Aio command settings.reload | Out-Null
    foreach ($entry in @('command', 'key', 'header')) {
        for ($sample = 1; $sample -le $Samples; $sample++) {
            Invoke-Aio command pane.split_right | Out-Null
            Invoke-Aio wait text 'PS ' | Out-Null
            Invoke-Aio run $Program --idle 1000 | Out-Null
            if ($Program -eq 'claude') { Invoke-Aio expect text 'Claude Code' | Out-Null }
            $state = Read-State
            $rect = $state["pane.$($state['panes.focused']).rect"] -split ','
            $scale = [double]$state['window.scale']
            $point = "$([int]([double]$rect[0]+[double]$rect[2]-16*$scale)),$([int]([double]$rect[1]+14*$scale))"
            $timer = [Diagnostics.Stopwatch]::StartNew()
            switch ($entry) {
                command { Invoke-Aio command pane.close | Out-Null }
                key { Invoke-Aio key Ctrl+Alt+W | Out-Null }
                header { Invoke-Aio mouse click $point --px | Out-Null }
            }
            Invoke-Aio expect state panes.count=1 | Out-Null
            $timer.Stop()
            $measurements += [pscustomobject]@{ entry = $entry; sample = $sample; close_ms = $timer.ElapsedMilliseconds }
            Write-Output "$entry sample=$sample close_ms=$($timer.ElapsedMilliseconds)"
        }
    }
    $measurements | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $data 'close-times.json')
    foreach ($entry in @('command', 'key', 'header')) {
        $times = @($measurements | Where-Object entry -eq $entry | Select-Object -ExpandProperty close_ms | Sort-Object)
        $median = $times[[int][Math]::Floor($times.Count / 2)]
        if ($median -gt $LimitMs) { throw "$entry median_ms=$median exceeds limit_ms=$LimitMs" }
        Write-Output "PASS $entry median_ms=$median limit_ms=$LimitMs"
    }
    Invoke-Aio doctor | Write-Output
} finally {
    Invoke-Aio stop | Write-Output
}
