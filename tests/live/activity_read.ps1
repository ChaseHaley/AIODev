param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'activity-read'
$data = Join-Path $repo "build/verify/$name"
function Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    return $result
}
function State {
    $s = @{}
    foreach ($line in (Aio state)) {
        $pair = $line -split '=', 2
        $s[$pair[0]] = $pair[1].Trim('"')
    }
    return $s
}
function Rect($s, $key) { return @($s[$key] -split ',' | ForEach-Object { [double]$_ }) }
function Middle($r) { return "$([int]($r[0]+$r[2]/2)),$([int]($r[1]+$r[3]/2))" }
function Equal($actual, $expected, $label) {
    if ("$actual" -ne "$expected") { throw "$label expected $expected, observed $actual" }
    Write-Output "PASS $label"
}
# The Activity row whose report says `message`, or none. Rows are named by their pane; the message is
# one of the terms after the name.
function Row($message) {
    $s = State
    for ($i = 0; $s.ContainsKey("activity.row.$i.rect"); $i++) {
        if ($s["activity.row.$i.report"] -eq 'true' -and $s["activity.row.$i.terms"] -like "*$message*") {
            return [pscustomobject]@{
                Rect = Rect $s "activity.row.$i.rect"; Receipt = Rect $s "activity.row.$i.receipt_rect"
                Read = $s["activity.row.$i.read"]; Text = $s["activity.row.$i.receipt"]
                Age = $s["activity.row.$i.state_age"]
            }
        }
    }
    return $null
}
function Await-Row($title, $read, $label) {
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $row = Row $title
        if ($row -and "$($row.Read)" -eq "$read") { Write-Host "PASS $label"; return $row }
        Start-Sleep -Milliseconds 100
    }
    throw "$label expected read=$read, observed $(Row $title | ConvertTo-Json -Compress)"
}

Aio launch --fresh --size 150x46 | Out-Null
try {
    Aio wait text 'PS ' | Out-Null
    # Only a focused window reads the pane it shows.
    Aio focus in | Out-Null
    $top = (State)['panes.focused']
    # A child PowerShell stands in for Claude: it reports done after a moment, then keeps running like
    # an agent at its prompt. Its end returns the pane to the shell, which process polling sees.
    $agent = "$data/agent.ps1"
    Set-Content -LiteralPath $agent -Value @(
        'Start-Sleep -Seconds 3'
        "[Console]::Write([char]27 + ']7501;state=done:id=claude:app=claude:msg=U3RhdHVzIHJvc3Rlcg==' + [char]7)"
        'Start-Sleep -Seconds 900'
    )
    Aio run "pwsh -NoProfile -File '$agent'" | Out-Null
    Aio command pane.split_down | Out-Null
    Aio wait text 'PS ' | Out-Null
    $bottom = (State)['panes.focused']
    if ($bottom -eq $top) { throw 'split did not move focus' }

    $row = Await-Row 'Status roster' 'false' 'a finish elsewhere is unread'
    Aio capture --out "$data/unread.png" | Out-Null

    # Viewing reads it; leaving keeps it, read, with its read time.
    Aio mouse click (Middle $row.Rect) --px | Out-Null
    Equal (State)['panes.focused'] $top 'the row goes to its pane'
    $row = Await-Row 'Status roster' 'true' 'viewing reads it'
    Equal $row.Text 'now' 'the receipt reads now while in view'
    Aio command pane.focus_down | Out-Null
    $row = Await-Row 'Status roster' 'true' 'leaving keeps the read row while its program runs'
    if ($row.Text -notmatch '^\d+s$') { throw "receipt after leaving shows $($row.Text)" }
    Write-Output "PASS the receipt shows when it was read ($($row.Text))"
    Aio capture --out "$data/read.png" | Out-Null

    # The receipt marks it unread and read again without leaving the pane in view.
    Aio mouse click (Middle $row.Receipt) --px | Out-Null
    $row = Await-Row 'Status roster' 'false' 'the receipt marks it unread'
    Equal (State)['panes.focused'] $bottom 'the receipt does not move focus'
    Aio mouse click (Middle $row.Receipt) --px | Out-Null
    $row = Await-Row 'Status roster' 'true' 'the receipt marks it read'

    # The row's menu does the same.
    Aio mouse click (Middle $row.Rect) --px --button right | Out-Null
    Equal (State)['overlay'] 'activity_row_menu' 'right click opens the row menu'
    Aio capture --out "$data/menu.png" | Out-Null
    Aio key Down Enter | Out-Null
    $row = Await-Row 'Status roster' 'false' 'the menu marks it unread'

    # U in the inbox reads the selected row.
    Aio command status.inbox | Out-Null
    Aio capture --out "$data/inbox.png" | Out-Null
    Aio key U | Out-Null
    $row = Await-Row 'Status roster' 'true' 'U in the inbox reads it'
    Aio key Esc | Out-Null

    # Once its program ends, read finished work leaves; unread work stays until it is read.
    Aio mouse click (Middle $row.Rect) --px | Out-Null
    Aio key Ctrl+C | Out-Null
    # The pane already shows a prompt from before, so give the new one time to arrive.
    Start-Sleep -Seconds 2
    $row = Row 'Status roster'
    Aio mouse click (Middle $row.Receipt) --px | Out-Null
    Await-Row 'Status roster' 'false' 'marked unread in view' | Out-Null
    Aio command pane.focus_down | Out-Null
    Await-Row 'Status roster' 'false' 'unread finished work outlives its program' | Out-Null
    $row = Row 'Status roster'
    Aio mouse click (Middle $row.Receipt) --px | Out-Null
    $deadline = (Get-Date).AddSeconds(10)
    while ((Row 'Status roster') -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (Row 'Status roster') { throw 'read finished work of an ended program stayed' }
    Write-Output 'PASS read finished work leaves once its program has ended'

    # WORK-424: a working program is read only while its pane is in view; out of view it has output
    # the user has not seen, and its receipt goes to the pane instead of marking it.
    $worker = "$data/worker.ps1"
    Set-Content -LiteralPath $worker -Value @(
        "[Console]::Write([char]27 + ']7501;state=working:id=worker:app=claude:msg=QnVzeSB3b3JrZXI=' + [char]7)"
        'Start-Sleep -Seconds 900'
    )
    Aio run "pwsh -NoProfile -File '$worker'" | Out-Null
    Await-Row 'Busy worker' 'true' 'a working pane in view is read' | Out-Null
    Aio command pane.focus_up | Out-Null
    $row = Await-Row 'Busy worker' 'false' 'leaving a working pane leaves it unread'
    if ($row.Text -notmatch '^\d+s$') { throw "working receipt after leaving shows $($row.Text)" }
    Write-Output "PASS the working receipt still shows when it was read ($($row.Text))"
    Aio capture --out "$data/working.png" | Out-Null
    Aio mouse click (Middle $row.Receipt) --px | Out-Null
    Equal (State)['panes.focused'] $bottom 'the working receipt goes to its pane'
    Await-Row 'Busy worker' 'true' 'going to it reads it' | Out-Null
    Aio key Ctrl+C | Out-Null
} finally { & $ctl --name $name stop | Out-Null }
