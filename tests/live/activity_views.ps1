param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'activity-views'
$data = Join-Path $repo "build/verify/$name"
$settings = "$data/settings.ini"
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
function Equal($actual, $expected, $label) {
    if ("$actual" -ne "$expected") { throw "$label expected $expected, observed $actual" }
    Write-Output "PASS $label"
}
function Middle($r) { return "$([int]($r[0]+$r[2]/2)),$([int]($r[1]+$r[3]/2))" }
function Click($s, $key) { Aio mouse click (Middle (Rect $s $key)) --px | Out-Null }
function Rows($s) {
    $rows = @()
    for ($i = 0; $s.ContainsKey("activity.row.$i.rect"); $i++) {
        $rows += [pscustomobject]@{
            Index = $i; Text = $s["activity.row.$i.text"]; Report = $s["activity.row.$i.report"] -eq 'true'
            Depth = [int]$s["activity.row.$i.depth"]; Rect = Rect $s "activity.row.$i.rect"
        }
    }
    return $rows
}
function Find-Row($s, $text) {
    $row = Rows $s | Where-Object { $_.Report -and $_.Text -eq $text } | Select-Object -First 1
    if (-not $row) { throw "no Activity row named $text" }
    return $row
}
function Encode($text) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) }
function Report-Script($file, $reports) {
    $body = @('$e = [char]27')
    foreach ($r in $reports) {
        $fields = "state=$($r.state)"
        foreach ($key in 'id', 'app', 'kind', 'progress') {
            if ($r.$key) { $fields += ":$key=$($r.$key)" }
        }
        if ($r.title) { $fields += ":title=$(Encode $r.title)" }
        if ($r.msg) { $fields += ":msg=$(Encode $r.msg)" }
        $body += "[Console]::Write(`$e + ']7501;$fields' + [char]7)"
    }
    # A new prompt clears running reports, so the script stays in the foreground.
    $body += 'Start-Sleep -Seconds 900'
    Set-Content -LiteralPath $file -Value $body
    Aio run "& '$file'" | Out-Null
}
function Set-Theme($theme) {
    $text = (Get-Content -Raw -LiteralPath $settings) -replace '(?m)^theme\.name = .*\r?\n?', ''
    [IO.File]::WriteAllText($settings, $text.TrimEnd() + "`ntheme.name = $theme`n")
    Aio command settings.reload | Out-Null
}
function Set-View-Button($view) {
    $s = State
    if ($s['activity.view'] -ne $view) { Click $s 'activity.view_button' }
    Equal (State)['activity.view'] $view "header button shows $view"
}

$agents = @(
    @{ state = 'blocked'; id = 'a'; app = 'claude'; kind = 'permission'; title = 'Activity panel'; msg = 'Approve edits to src/layout.odin' }
    @{ state = 'working'; id = 'a/review'; app = 'codex'; title = 'Review layout'; msg = 'Checking the layout changes' }
    @{ state = 'working'; id = 'b'; app = 'codex'; title = 'Workspace picker'; msg = 'Refining the workspace picker' }
    @{ state = 'working'; id = 'c'; app = 'Release'; progress = 64; title = 'Release build'; msg = 'Compiling release' }
    @{ state = 'error'; id = 'd'; app = 'codex'; title = 'Deploy website'; msg = 'Deployment failed: token expired' }
)
$others = @(
    @{ state = 'blocked'; id = 'e'; app = 'claude'; kind = 'question'; title = 'Mobile layout'; msg = 'Keep the existing mobile layout?' }
    @{ state = 'done'; id = 'f'; app = 'gemini'; title = 'Client tests'; msg = '142 tests passed' }
    @{ state = 'idle'; id = 'g'; app = 'codex'; title = 'Schema migration'; msg = 'Waiting for the next task' }
    @{ state = 'working'; id = 'h'; title = 'No program named' }
)

Aio launch --fresh --size 150x46 | Out-Null
try {
    Add-Content -LiteralPath $settings -Value "`nstatus.panel = true`nstatus.show_idle = true`nstatus.show_done = true"
    Aio command settings.reload | Out-Null
    $s = State
    Equal $s['activity.view'] 'comfy' 'no saved value opens Comfy'
    Equal (@(Rows $s).Count) 0 'empty panel has no rows'
    Aio capture --out "$data/empty-comfy.png" | Out-Null
    Aio wait text 'PS ' | Out-Null
    Report-Script "$data/agents.ps1" $agents
    Aio command pane.split_down | Out-Null
    Aio wait text 'PS ' | Out-Null
    Report-Script "$data/others.ps1" $others
    Start-Sleep -Milliseconds 500

    $s = State
    $rows = Rows $s
    Equal (@($rows | Where-Object Report).Count) 9 'every report has a row'
    Equal (Find-Row $s 'Review layout').Depth 1 'child report keeps its parent'
    Equal ($rows[0].Report) $false 'Comfy starts with a workspace label'
    Equal ([int]((Find-Row $s 'Activity panel').Rect[3])) ([int](56 * [double]$s['window.scale'])) 'Comfy row height'

    # Settings and the header change one saved value.
    Add-Content -LiteralPath $settings -Value "`nstatus.panel_view = dense"
    Aio command settings.reload | Out-Null
    $s = State
    Equal $s['activity.view'] 'dense' 'saved Dense reaches the panel'
    $rows = Rows $s
    Equal ($rows[0].Text) 'Needs you' 'Dense leads with what needs you'
    Equal ([int]((Find-Row $s 'Activity panel').Rect[3])) ([int](32 * [double]$s['window.scale'])) 'Dense row height'
    Set-View-Button 'comfy'
    if (-not (Select-String -LiteralPath $settings -SimpleMatch 'status.panel_view = comfy' -Quiet)) {
        throw 'header button did not save the view'
    }
    Write-Output 'PASS header button saves the view'

    # A press released elsewhere changes nothing.
    $s = State
    $button = Rect $s 'activity.view_button'
    Aio mouse down (Middle $button) --px | Out-Null
    Aio mouse up "$([int]($button[0]-120)),$([int]($button[1]+200))" --px | Out-Null
    Equal (State)['activity.view'] 'comfy' 'release outside cancels'

    # Both views go to the pane and dismiss finished work.
    foreach ($view in 'comfy', 'dense') {
        Set-View-Button $view
        $s = State
        $focused = $s['panes.focused']
        $row = Find-Row $s 'Activity panel'
        Aio mouse click (Middle $row.Rect) --px | Out-Null
        $after = (State)['panes.focused']
        if ($after -eq $focused) { throw "$view row click stayed on pane $focused" }
        Write-Output "PASS $view row goes to its pane"
        Aio mouse click (Middle (Find-Row (State) 'Workspace picker').Rect) --px | Out-Null
        Aio mouse click (Middle (Find-Row (State) 'Mobile layout').Rect) --px | Out-Null
        Equal (State)['panes.focused'] $focused "$view returns to the other pane"
    }

    # Tooltips name the whole report.
    $row = Find-Row (State) 'Deploy website'
    Aio mouse move "$([int]($row.Rect[0]+60)),$([int]($row.Rect[1]+$row.Rect[3]/2))" --px | Out-Null
    Start-Sleep -Milliseconds 900
    Aio capture --out "$data/tooltip-dense.png" | Out-Null

    foreach ($theme in 'studio-dark', 'studio-light') {
        Set-Theme $theme
        foreach ($dpi in 96, 144) {
            Aio dpi $dpi | Out-Null
            foreach ($view in 'comfy', 'dense') {
                Set-View-Button $view
                Aio mouse move '5,5' --px | Out-Null
                Start-Sleep -Milliseconds 300
                Aio capture --out "$data/$view-$theme-$dpi.png" | Out-Null
            }
        }
    }
    Aio dpi 96 | Out-Null
    Set-Theme 'studio-dark'

    # Left docking and the vertical rail keep the button beside the side button.
    $s = State
    Click $s 'activity.side_button'
    Equal (State)['activity.side'] 'left' 'panel docks left'
    Aio capture --out "$data/left-dock.png" | Out-Null
    if ((State)['tabs.orientation'] -ne 'vertical') { Aio command view.tabs_orientation | Out-Null }
    foreach ($view in 'comfy', 'dense') {
        Set-View-Button $view
        Start-Sleep -Milliseconds 200
        Aio capture --out "$data/rail-$view.png" | Out-Null
    }

    # A short panel overflows and scrolls, and row rects follow the scroll.
    $s = State
    $last = @(Rows $s)[-1]
    $panel = Rect $s 'activity.rect'
    if ($last.Rect[1] + $last.Rect[3] -le $panel[1] + $panel[3]) { throw 'rail panel did not overflow' }
    $first = @(Rows $s)[0].Rect[1]
    Aio mouse wheel "$([int]($panel[0]+40)),$([int]($panel[1]+80))" -1 --px | Out-Null
    $moved = @(Rows (State))[0].Rect[1]
    if ($moved -ge $first) { throw "wheel left the first row at $moved" }
    Write-Output 'PASS rail panel scrolls'
    Aio capture --out "$data/rail-scrolled.png" | Out-Null

    # Finished work dismisses from its row in both views.
    Aio command view.tabs_orientation | Out-Null
    $s = State
    Click $s 'activity.side_button'
    Set-View-Button 'dense'
    $s = State
    $row = Find-Row $s 'Client tests'
    $x, $y = [int]($row.Rect[0]+$row.Rect[2]-16*[double]$s['window.scale']), [int]($row.Rect[1]+$row.Rect[3]/2)
    Aio mouse move "$x,$y" --px | Out-Null
    Aio capture --out "$data/dismiss-dense.png" | Out-Null
    Aio mouse click "$x,$y" --px | Out-Null
    Start-Sleep -Milliseconds 300
    Equal (@(Rows (State) | Where-Object Report).Count) 8 'Dense dismiss removes the report'
    Set-View-Button 'comfy'
    $s = State
    $row = Find-Row $s 'Deploy website'
    $x, $y = [int]($row.Rect[0]+$row.Rect[2]-16*[double]$s['window.scale']), [int]($row.Rect[1]+16*[double]$s['window.scale'])
    Aio mouse move "$x,$y" --px | Out-Null
    Aio capture --out "$data/dismiss-comfy.png" | Out-Null
    Aio mouse click "$x,$y" --px | Out-Null
    Start-Sleep -Milliseconds 300
    Equal (@(Rows (State) | Where-Object Report).Count) 7 'Comfy dismiss removes the report'

    # The saved view survives a restart.
    Set-View-Button 'dense'
    $persisted = Join-Path $data 'persisted.ini'
    Copy-Item -LiteralPath $settings -Destination $persisted
    & $ctl --name $name stop | Out-Null
    Aio launch --settings $persisted | Out-Null
    Equal (State)['activity.view'] 'dense' 'restart keeps the saved view'
} finally { & $ctl --name $name stop | Out-Null }
