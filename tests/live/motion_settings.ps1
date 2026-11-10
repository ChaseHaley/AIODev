[CmdletBinding()]
param()
# Changes the pane motion settings (WORK-383) on a running instance through settings.ini and proves each one
# changes the next split: a longer Split duration keeps the panes moving longer, Pop In shows the new pane at
# its full rectangle from the first frame while Grow from Side widens it, Split off lands at once while the
# other contexts still move, and the speed multiplier shortens the motion.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'motion-settings'
# The instance reads its own copy; settings.reload rereads it.
$settings = Join-Path $repo "build/verify/$name/settings.ini"
function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    $result | Write-Output
}
function Read-State {
    $values = @{}
    foreach ($line in (Invoke-Aio state)) { $pair = $line -split '=', 2; $values[$pair[0]] = $pair[1] }
    return $values
}
function Wait-Settled {
    for ($i = 0; $i -lt 100; $i++) {
        if ((Read-State)['ui.animating'] -eq 'false') { return }
        Start-Sleep -Milliseconds 50
    }
    throw 'Motion did not settle.'
}
function Configure([string] $Text) {
    Set-Content -LiteralPath $settings -Value $Text
    Invoke-Aio command settings.reload | Out-Null
    $notice = (Read-State)['notice.settings']
    if ($notice -like 'error:*' -or $notice -like 'warning:*') { throw "settings refused: $notice" }
}
# Runs `command`, then samples state until the panes stop moving. The control pipe serves one request at a
# time, and a command replies within about a second even while a longer motion runs, so a long motion is
# timed from the command's start and sampled after its reply. Returns how long the panes moved, at least,
# and every sample taken while they did.
function Measure-Motion([string[]] $Command) {
    Wait-Settled
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Invoke-Aio command @Command | Out-Null
    $samples = @()
    while ($clock.ElapsedMilliseconds -lt 10000) {
        $s = Read-State
        if ($s['panes.moving'] -ne 'true') { break }
        $samples += , $s
    }
    $moved = $clock.ElapsedMilliseconds
    Wait-Settled
    return [pscustomobject]@{ Moved = $moved; Samples = $samples }
}
# The pane whose drawn rectangle differs most from its layout rectangle in `s`, as [rect, shown] arrays.
function Widths($s) {
    foreach ($key in $s.Keys | Where-Object { $_ -like 'pane.*.rect' }) {
        $rect = $s[$key] -split ',' | ForEach-Object { [double]$_ }
        $shown = $s[($key -replace '\.rect$', '.shown')] -split ',' | ForEach-Object { [double]$_ }
        [pscustomobject]@{ Key = $key; Rect = $rect; Shown = $shown }
    }
}
function Close-Back {
    Invoke-Aio command pane.close | Out-Null
    Invoke-Aio expect state panes.count=1 | Out-Null
    Wait-Settled
}
try {
    Invoke-Aio launch --fresh | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Wait-Settled

    # A long Split motion keeps the panes moving well past the command's reply. Linear makes the new
    # pane's growth plain to see in every sample.
    Configure "motion.panes.split = 3000ms linear grow"
    $long = Measure-Motion @('pane.split_right')
    if ($long.Moved -lt 2500) { throw "a 3000 ms split moved for only $($long.Moved) ms" }
    # Grow from Side: frames draw the new pane narrower than its layout rectangle.
    $narrow = @($long.Samples | ForEach-Object { Widths $_ } | Where-Object { $_.Shown[2] -lt $_.Rect[2] - 1 })
    if (-not $narrow) { throw 'Grow from Side never drew a pane narrower than its rectangle' }
    Write-Output "PASS split 3000ms grow moved $($long.Moved) ms and widened the new pane"
    Close-Back

    # Pop In: the new pane draws at its full rectangle throughout; only the divided pane narrows.
    Configure "motion.panes.split = 3000ms linear popin"
    $pop = Measure-Motion @('pane.split_right')
    if ($pop.Moved -lt 2500) { throw "a 3000 ms pop-in split moved for only $($pop.Moved) ms" }
    if (-not $pop.Samples) { throw 'no sample caught the pop-in split moving' }
    $wrong = @($pop.Samples | ForEach-Object {
            # The right-hand pane is the new one.
            $new = @(Widths $_) | Sort-Object { $_.Rect[0] } | Select-Object -Last 1
            [Math]::Abs($new.Shown[2] - $new.Rect[2]) -le 1
        } | Where-Object { -not $_ })
    if ($wrong) { throw 'Pop In drew the new pane at another width than its rectangle' }
    Write-Output "PASS split 3000ms popin kept the new pane at its rectangle for $($pop.Samples.Count) samples"
    Close-Back

    # Split off lands at once, while Close, still inherited from Panes, keeps its motion.
    Configure "motion.panes.split = off`nmotion.panes.close = 3000ms"
    $off = Measure-Motion @('pane.split_right')
    if ($off.Samples.Count -gt 0) { throw "a split with Split off was still moving after the command" }
    $close = Measure-Motion @('pane.close')
    if ($close.Moved -lt 2500) { throw "a 3000 ms close moved for only $($close.Moved) ms" }
    Write-Output "PASS split off lands at once; close still moves $($close.Moved) ms"

    # Speed 4x divides every duration: 3200 ms plays in 800.
    Configure "motion.speed = 4`nmotion.panes.split = 3200ms"
    $fast = Measure-Motion @('pane.split_right')
    if ($fast.Moved -gt 2000) { throw "a 3200 ms split at 4x moved for $($fast.Moved) ms" }
    Write-Output "PASS speed 4x split settled within $($fast.Moved) ms"
    Close-Back

    # A user curve parses and drives a context without a settings problem.
    Configure "motion.curve.mine = 0.3, 1.4, 0.2, 1`nmotion.panes.split = 3000ms mine popin"
    $curve = Measure-Motion @('pane.split_right')
    if ($curve.Moved -lt 2500) { throw "a user curve split moved for only $($curve.Moved) ms" }
    Write-Output "PASS user curve split moved $($curve.Moved) ms"
    Invoke-Aio stop | Out-Null
    Write-Output 'PASS motion settings'
} finally {
    & $ctl --name $name stop 2>$null | Out-Null
}
