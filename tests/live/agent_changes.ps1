param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'agent-changes'
$data = [IO.Path]::GetFullPath((Join-Path $repo "build/verify/$name"))
# The repository the fake agent edits lives beside the instance data directory, which --fresh recreates.
$work = [IO.Path]::GetFullPath((Join-Path $repo "build/verify/$name-repo"))
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
# Clicks the middle of the control state names; extra arguments such as --mods Shift go to the click.
function Click-Rect($s, $key) {
    $r = Rect $s $key
    if ($r.Count -ne 4 -or $r[2] -le 0 -or $r[3] -le 0) { throw "$key is not shown: '$($s[$key])'" }
    Aio mouse click (Middle $r) --px @args | Out-Null
}
function Equal($actual, $expected, $label) {
    if ("$actual" -ne "$expected") { throw "$label expected $expected, observed $actual" }
    Write-Output "PASS $label"
}
# Like Equal, for text the journey knows only in part; `$pattern` is a wildcard pattern.
function Like($actual, $pattern, $label) {
    if ("$actual" -notlike $pattern) { throw "$label expected like $pattern, observed $actual" }
    Write-Output "PASS $label"
}
function Git {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & git.exe -C $work -c user.name=journey -c user.email=journey@example.invalid @args 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($code -ne 0) { throw "git $($args -join ' '): $out" }
}
# Polls the state until every pair in `$want` holds; `$want` maps a key to its expected text. The pass line
# goes straight to the console, because the state is this function's only pipeline output.
function Await-State($want, $label, $seconds = 15) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ($true) {
        $s = State
        $miss = @($want.Keys | Where-Object { "$($s[$_])" -ne "$($want[$_])" })
        if ($miss.Count -eq 0) { [Console]::Out.WriteLine("PASS $label"); return $s }
        if ((Get-Date) -ge $deadline) {
            $seen = ($miss | ForEach-Object { "$_=$($s[$_]) (want $($want[$_]))" }) -join ', '
            $files = @($s.Keys | Where-Object { $_ -like 'changes.file.*.path' } | Sort-Object |
                ForEach-Object { "$_=$($s[$_])" }) -join ', '
            throw "$label timed out: $seen; turns=$($s['changes.turns']) first=$($s['changes.first']) last=$($s['changes.last']) $files"
        }
        Start-Sleep -Milliseconds 100
    }
}
# Polls the state until `$key` matches the wildcard `$pattern`, for text the journey knows only in part.
# Like Await-State, it writes its pass line to the console and returns the state.
function Await-Like($key, $pattern, $label, $seconds = 15) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ($true) {
        $s = State
        if ("$($s[$key])" -like $pattern) { [Console]::Out.WriteLine("PASS $label"); return $s }
        if ((Get-Date) -ge $deadline) { throw "$label timed out: $key=$($s[$key]) (want like $pattern)" }
        Start-Sleep -Milliseconds 100
    }
}
# Waits until no notice shows. Notices sit at the window's bottom right, over the send bar of an Agent changes
# pane on that side, so a press meant for Copy or Send would land on a notice.
function Await-NoNotices($label, $seconds = 30) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ($true) {
        $s = State
        $shown = @($s.Keys -match '^notice\.[a-z_0-9]+(\.\d+)?$')
        if ($shown.Count -eq 0) { [Console]::Out.WriteLine("PASS $label"); return $s }
        if ((Get-Date) -ge $deadline) { throw "$label timed out: $($shown -join ', ')" }
        Start-Sleep -Milliseconds 200
    }
}
function Await-AtLeast($key, $count, $label, $seconds = 20) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $value = (State)[$key]
        if ($value -match '^\d+$' -and [int]$value -ge $count) { Write-Output "PASS $label"; return }
        Start-Sleep -Milliseconds 100
    }
    throw "$label expected $key >= $count, observed $((State)[$key])"
}
function Await-File($path, $label, $seconds = 30) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $path) { Write-Output "PASS $label"; return }
        Start-Sleep -Milliseconds 100
    }
    throw "$label timed out waiting for $path"
}
function Turn-Directories {
    if (-not (Test-Path -LiteralPath $data)) { return @() }
    return @(Get-ChildItem -LiteralPath $data -Recurse -Directory -Filter 'agent-turns*' -ErrorAction SilentlyContinue)
}
function File-Row($s, $path) {
    for ($i = 0; $s.ContainsKey("changes.file.$i.path"); $i++) {
        if ($s["changes.file.$i.path"] -eq $path) { return $i }
    }
    throw "changes.file has no $path; saw $(@(0..9 | ForEach-Object { $s["changes.file.$_.path"] }) -join ',')"
}
# The source dropdown's position of the agent whose label contains `$needle`, such as its pane's title.
function Agent-Index($s, $needle) {
    for ($i = 0; $i -lt [int]$s['changes.agents']; $i++) {
        if ($s["changes.agent.$i.label"] -like "*$needle*") { return $i }
    }
    $labels = @($s.Keys | Where-Object { $_ -like 'changes.agent.*.label' } | Sort-Object |
        ForEach-Object { "$_=$($s[$_])" }) -join ', '
    throw "no agent label contains $needle; saw $labels"
}
# Shows `$key`'s rectangle, which the state reports as zero or leaves out while the part is not drawn.
function Assert-Shown($s, $key) {
    $r = Rect $s $key
    if ($r.Count -ne 4 -or $r[2] -le 0 -or $r[3] -le 0) { throw "$key expected shown, observed '$($s[$key])'" }
    Write-Output "PASS $key is shown"
}
function Assert-Hidden($s, $key) {
    if (-not $s[$key]) { Write-Output "PASS $key is not reported"; return }
    $r = Rect $s $key
    if ($r.Count -eq 4 -and ($r[2] -gt 0 -or $r[3] -gt 0)) { throw "$key expected hidden, observed '$($s[$key])'" }
    Write-Output "PASS $key is hidden"
}
# Opens the focused pane's panel through the row's summary when it is closed. Returns the state with the
# panel open.
function Open-Panel {
    $s = State
    if ($s['changes.panel_open'] -eq 'true') { return $s }
    Click-Rect $s 'changes.summary_rect'
    return Await-State @{ 'changes.panel_open' = 'true'; 'changes.dropdown_open' = 'false' } 'the summary opens the panel'
}
# Opens the file list through the row's files button, which closes the panel when it is open.
function Open-Files {
    $s = State
    if ($s['changes.files_open'] -eq 'true') { return $s }
    Click-Rect $s 'changes.files_button_rect'
    return Await-State @{ 'changes.files_open' = 'true'; 'changes.dropdown_open' = 'true'; 'changes.panel_open' = 'false' } 'the files button opens the file list'
}
# Esc closes the panel.
function Close-Panel {
    Aio key Esc | Out-Null
    return Await-State @{ 'changes.panel_open' = 'false'; 'changes.dropdown_open' = 'false' } 'Escape closes the panel'
}
# Picks source chip `$index` of the focused pane's panel: the agents, All agents, then Uncommitted, Staged
# and Unstaged changes. The panel stays open after a pick; this closes it.
function Choose-Source($index, $label) {
    $s = Open-Panel
    Click-Rect $s "changes.source_chip.$index.rect"
    Await-State @{ 'changes.source_chip_current' = $index } "the source chip picks ($label)" | Out-Null
    Close-Panel | Out-Null
}
# Polls until a number the state reports is below `$limit`.
function Await-Below($key, $limit, $label, $seconds = 10) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if ([double](State)[$key] -lt $limit) { Write-Output "PASS $label"; return }
        Start-Sleep -Milliseconds 100
    }
    throw "$label expected $key < $limit, observed $((State)[$key])"
}
# Resizes the window to `$cols` columns. aioctl confirms a resize by the focused terminal's grid equalling the
# request, which holds for no pane of a split tab, and an Agent changes pane has no terminal at all; the window
# still resizes, so that one timeout reply is accepted and the journey reads the row's steps instead.
function Resize-Window($cols) {
    $result = & $ctl --name $name resize "${cols}x46" 2>&1
    if ($LASTEXITCODE -ne 0 -and "$result" -notlike '*resize timed out*') { throw "aioctl resize ${cols}x46: $result" }
    Start-Sleep -Milliseconds 600
}
# Worktrees the journey adds beside the repository; the picker reports them with '/' separators.
$wtA = "$work-wt-a"
$wtB = "$work-wt-b"
$workPath = $work -replace '\\', '/'
$wtAPath = $wtA -replace '\\', '/'
function Remove-Worktree($path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git.exe -C $work worktree remove --force $path 2>&1 | Out-Null
    $ErrorActionPreference = $previous
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
}
function Focus-Pane($node) {
    $s = State
    Click-Rect $s "pane.$node.rect"
    Await-State @{ 'panes.focused' = $node } "pane $node takes focus" | Out-Null
}
# Opens a new Agent changes pane beside the pane; its scope is Agent because the pane reported agent status.
function Open-Changes($node, $label) {
    Focus-Pane $node
    Aio command pane.agent_changes | Out-Null
    $want = @{ 'changes.active' = 'true'; 'changes.scope' = 'agent'; 'changes.loaded' = 'true'; 'changes.settled' = 'true' }
    return Await-State $want $label
}
# Closes the focused Agent changes pane like any pane; `$panes` is how many the tab keeps. The app frees
# panes nothing shows on its next poll, so an earlier close may lower the count further.
function Close-Changes($panes) {
    $s = State
    if ($s['changes.active'] -ne 'true') { throw "closing expects an Agent changes pane, focused $($s['panes.focused'])" }
    $before = [int]$s['changes.count']
    Aio command pane.close | Out-Null
    Await-State @{ 'panes.count' = $panes } 'Agent changes closes' | Out-Null
    $deadline = (Get-Date).AddSeconds(15)
    while ([int](State)['changes.count'] -ge $before) {
        if ((Get-Date) -ge $deadline) { throw "closing expected changes.count below $before, observed $((State)['changes.count'])" }
        Start-Sleep -Milliseconds 100
    }
}
# Types into the focused shell, so a marker the command prints tells that the folder changed.
function Start-Worker($directory, $marker, $target, $file, $mine, $other) {
    Aio run "cd '$directory'; Write-Output ('READY_' + '$marker')" | Out-Null
    Aio wait text "READY_$marker" | Out-Null
    Aio run "pwsh -NoProfile -File '$worker' -Target '$target' -Name '$file' -Mine '$mine' -Other '$other'" | Out-Null
}
# A new tab with two shells side by side, each running the worker; returns the two pane nodes.
function Start-Pair($tab, $tag, $directoryA, $directoryB, $targetA, $targetB, $fileA, $fileB) {
    Aio command tab.new | Out-Null
    Await-State @{ 'tabs.count' = $tab; 'tabs.selected' = $tab } "tab $tab opens" | Out-Null
    Aio wait text 'PS ' | Out-Null
    $nodeA = (State)['panes.focused']
    $flagA = "$data/$tag-a.flag"
    $flagB = "$data/$tag-b.flag"
    Start-Worker $directoryA "${tag}A" $targetA $fileA $flagA $flagB
    Aio command pane.split_right | Out-Null
    Await-State @{ 'panes.count' = 2 } "tab $tab splits" | Out-Null
    Aio wait text 'PS ' | Out-Null
    $nodeB = (State)['panes.focused']
    Start-Worker $directoryB "${tag}B" $targetB $fileB $flagB $flagA
    return @($nodeA, $nodeB)
}

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
foreach ($path in @($wtA, $wtB)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
New-Item -ItemType Directory -Path $work | Out-Null
Git init -q
Set-Content -LiteralPath (Join-Path $work 'a.txt') -Value @('one', 'two', 'three')
Set-Content -LiteralPath (Join-Path $work 'b.txt') -Value @('keep', 'drop')
# Only the reviewer of section (d) edits it, for a modified file whose two sides show side by side. Its
# changed line is long on both sides, wider than a pane, so the long-line checks have lines to scroll: the
# digit groups make every byte tell its place.
$wideOld = 'beta ' + ((1..50 | ForEach-Object { '{0:D3}_' -f $_ }) -join '')
$wideNew = 'BETA ' + ((1..70 | ForEach-Object { '{0:D3}_' -f $_ }) -join '')
Set-Content -LiteralPath (Join-Path $work 'notes.txt') -Value @('alpha', $wideOld, 'gamma', 'delta')
Git add -A
Git commit -q -m initial

Aio launch --fresh --size 150x46 | Out-Null
try {
    Aio wait text 'PS ' | Out-Null
    Aio focus in | Out-Null

    # Recording is off by default; the journey turns it on through settings like a user editing the file.
    Equal (State)['turns.recording'] false 'turn recording starts off'
    Add-Content -LiteralPath "$data/settings.ini" -Value "`nturns.record = true"
    Aio command settings.reload | Out-Null
    Aio expect state turns.recording=true | Out-Null
    Write-Output 'PASS the setting turns recording on'

    # Every fake agent reports through OSC 7501 with no id, which is its pane's main record, and names its
    # pane through the console title so the source dropdown's agent labels tell the agents apart.
    $report = @(
        'function Report($state, $message) {'
        '    $text = "]7501;state=$state" + ":app=claude"'
        '    if ($message) { $text += ":msg=" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($message)) }'
        '    [Console]::Write([char]27 + $text + [char]7)'
        '}'
    )
    # Between its two turns the agent waits for the flag the journey creates after it has edited a.txt
    # from outside.
    $go = "$data/go.flag"
    $finished = "$data/finished.flag"
    $agent = "$data/agent.ps1"
    $go3 = "$data/go3.flag"
    $finished3 = "$data/finished3.flag"
    $worker = "$data/worker.ps1"
    Set-Content -LiteralPath $agent -Value (@(
        "`$work = '$work'"
        "`$go = '$go'"
        "`$go3 = '$go3'"
        "`$finished3 = '$finished3'"
        "`$wtA = '$wtA'"
        "`$finished = '$finished'"
    ) + $report + @(
        '$Host.UI.RawUI.WindowTitle = ''Journey agent'''
        "Report 'working' ''"
        'Start-Sleep -Milliseconds 500'
        "Add-Content -LiteralPath (Join-Path `$work 'a.txt') -Value 'agent line one'"
        "Set-Content -LiteralPath (Join-Path `$work 'c.txt') -Value @('new', 'file')"
        'Start-Sleep -Seconds 1'
        "Report 'done' 'First'"
        'Start-Sleep -Seconds 1'
        'while (-not (Test-Path -LiteralPath $go)) { Start-Sleep -Milliseconds 100 }'
        'Start-Sleep -Seconds 1'
        "Report 'working' ''"
        'Start-Sleep -Milliseconds 500'
        "Add-Content -LiteralPath (Join-Path `$work 'a.txt') -Value 'agent line two'"
        "Remove-Item -LiteralPath (Join-Path `$work 'b.txt')"
        'Start-Sleep -Seconds 1'
        "Report 'done' 'Second'"
        'Start-Sleep -Seconds 2'
        "Set-Content -LiteralPath `$finished -Value 'x'"
        'Start-Sleep -Seconds 1'
        'while (-not (Test-Path -LiteralPath $go3)) { Start-Sleep -Milliseconds 100 }'
        'Start-Sleep -Seconds 1'
        "Report 'working' ''"
        'Start-Sleep -Milliseconds 500'
        '& git.exe -C $work worktree add $wtA -b agent-a *> $null'
        'Start-Sleep -Milliseconds 500'
        "Add-Content -LiteralPath (Join-Path `$wtA 'a.txt') -Value 'agent line in worktree'"
        'Start-Sleep -Seconds 1'
        "Report 'done' 'Third'"
        'Start-Sleep -Seconds 2'
        "Set-Content -LiteralPath `$finished3 -Value 'x'"
        'Start-Sleep -Seconds 900'
    ))
    Aio run "cd '$work'" | Out-Null
    Aio wait text 'agent-changes-repo' | Out-Null
    $agentPane = (State)['panes.focused']
    Aio run "pwsh -NoProfile -File '$agent'" | Out-Null

    Await-AtLeast 'turns.saved' 1 'the first turn is saved' | Out-Null
    # Between the turns, outside any agent turn. a.txt changes in both turns too, so a run over both turns
    # shows this edit inside a.txt's net diff and must mark it; a single turn must not include it.
    Add-Content -LiteralPath (Join-Path $work 'a.txt') -Value 'owner line between turns'
    Start-Sleep -Milliseconds 800
    Set-Content -LiteralPath $go -Value 'x'
    Await-File $finished 'the agent finished its second turn' | Out-Null
    Await-AtLeast 'turns.saved' 2 'the second turn is saved'
    Equal (State)['turns.last_error'] '' 'recording reports no error'

    # Agent scope lists only this pane's Turn rows, newest selected.
    Aio command pane.agent_changes | Out-Null
    $s = Await-State @{
        'changes.count' = 1; 'changes.scope' = 'agent'; 'changes.turns' = 2; 'changes.settled' = 'true'
        'changes.first' = 0; 'changes.last' = 0; 'changes.files' = 2
        'changes.file.0.path' = 'a.txt'; 'changes.file.1.path' = 'b.txt'
    } 'the pane opens on the agent scope with the newest turn selected'
    Equal $s['changes.active'] true 'the command focuses the new Agent changes pane'
    $changesPane = $s['panes.focused']
    if ($changesPane -eq $agentPane) { throw "the Agent changes pane expected beside $agentPane, observed it" }
    Write-Output 'PASS the command opens a pane beside the agent'
    Equal $s['changes.agents'] 1 'the source dropdown lists the one agent'
    Like $s['changes.agent'] '*Journey agent*' "the source field names the agent by its pane's title"
    Equal $s['changes.turn.0.live'] false 'a finished turn is not live'
    Equal $s['changes.file.0.path'] 'a.txt' 'the newest turn lists a.txt first'
    Equal $s['changes.file.1.path'] 'b.txt' 'the newest turn lists b.txt second'
    if ([int]$s['changes.file.1.removed'] -le 0) { throw "b.txt removed expected > 0, observed $($s['changes.file.1.removed'])" }
    Write-Output 'PASS the deleted file shows removed lines'
    Equal $s['changes.file.0.added'] 1 'the newest turn shows only its own a.txt line'
    Equal $s['changes.file.0.marked'] false 'an edit before the turn began is not marked in it'

    # The panel holds the turn strip, one bar per turn, oldest at the left; turns are numbered oldest = 1.
    # Closed, the panel shows none of its parts.
    Equal $s['changes.panel_open'] false 'the panel starts closed'
    Assert-Hidden $s 'changes.strip.0.rect'
    Assert-Hidden $s 'changes.step_back_rect'
    $s = Open-Panel
    Equal $s['changes.dropdown_open'] false 'opening the panel opens no file list'
    $newest = Rect $s 'changes.strip.0.rect'
    $older = Rect $s 'changes.strip.1.rect'
    if (-not ($newest[2] -gt 0 -and $older[2] -gt 0 -and $newest[0] -gt $older[0])) {
        throw "strip bars expected the newest right of the older, observed $($newest -join ',') and $($older -join ',')"
    }
    Write-Output 'PASS the strip shows the newest turn right of the older one'
    Equal $s['changes.range_label'] 'Turn 2' 'the range label numbers the newest turn'
    # Left and Right step the turns while the panel is open and no file list is.
    Aio key Left | Out-Null
    $s = Await-State @{
        'changes.first' = 1; 'changes.last' = 1; 'changes.files' = 2; 'changes.range_label' = 'Turn 1'
        'changes.settled' = 'true'; 'changes.file.0.path' = 'a.txt'; 'changes.file.1.path' = 'c.txt'
    } 'Left steps to the older turn'
    Equal $s['changes.file.0.path'] 'a.txt' 'the first turn lists a.txt'
    Equal $s['changes.file.1.path'] 'c.txt' 'the first turn lists the new c.txt'
    $s = Open-Panel
    Click-Rect $s 'changes.step_forward_rect'
    $s = Await-State @{
        'changes.first' = 0; 'changes.last' = 0; 'changes.range_label' = 'Turn 2'; 'changes.settled' = 'true'
        'changes.file.1.path' = 'b.txt'
    } 'the forward step selects the newer turn'
    Click-Rect $s 'changes.step_back_rect'
    $s = Await-State @{ 'changes.first' = 1; 'changes.last' = 1; 'changes.settled' = 'true'; 'changes.file.1.path' = 'c.txt' } `
        'the back step selects the older turn'
    Close-Panel | Out-Null
    Aio key Shift+Right | Out-Null
    $s = Await-State @{ 'changes.first' = 0; 'changes.last' = 1; 'changes.files' = 3; 'changes.settled' = 'true' } `
        'Shift+Right extends the selection over both turns'
    # The en dash arrives escaped, so only the ends of the label are compared.
    Like $s['changes.range_label'] 'Turns 1*2' 'the range label names the selected run'
    # The range label opens the turn list; Escape closes it.
    $s = Open-Panel
    Click-Rect $s 'changes.range_label_rect'
    $s = Await-State @{ 'changes.turn_list_open' = 'true'; 'changes.dropdown_open' = 'false' } `
        'the range label opens the turn list over the panel'
    Aio key Esc | Out-Null
    $s = Await-State @{
        'changes.turn_list_open' = 'false'; 'changes.panel_open' = 'true'; 'changes.dropdown_open' = 'false'
        'changes.first' = 0; 'changes.last' = 1; 'changes.settled' = 'true'
    } 'Escape closes the turn list and keeps the selection and the panel'
    # A click on the newest bar selects it alone; Shift+click on the older bar extends the selection again.
    Click-Rect $s 'changes.strip.0.rect'
    $s = Await-State @{
        'changes.first' = 0; 'changes.last' = 0; 'changes.files' = 2; 'changes.settled' = 'true'
        'changes.file.1.path' = 'b.txt'
    } 'a click on a bar selects its turn'
    Click-Rect $s 'changes.strip.1.rect' --mods Shift
    $s = Await-State @{
        'changes.first' = 0; 'changes.last' = 1; 'changes.files' = 3; 'changes.settled' = 'true'
        'changes.file.0.path' = 'a.txt'; 'changes.file.1.path' = 'b.txt'; 'changes.file.2.path' = 'c.txt'
    } 'Shift+click on the older bar extends the selection over both turns'
    Equal $s['changes.file.0.path'] 'a.txt' 'the run lists a.txt'
    Equal $s['changes.file.1.path'] 'b.txt' 'the run lists b.txt'
    Equal $s['changes.file.2.path'] 'c.txt' 'the run lists c.txt'
    Equal $s['changes.file.0.added'] 3 'a.txt nets both agent lines and the edit between them'
    Equal $s['changes.file.0.marked'] true 'a.txt is marked as also changed between the turns'
    Equal $s['changes.file.1.marked'] false 'b.txt is not marked'
    Equal $s['changes.file.2.marked'] false 'c.txt, changed only in the first turn, is not marked'
    Aio capture --out "$data/agent-turns.png" | Out-Null

    # Uncommitted scope through the source dropdown: the agent, All agents, then Uncommitted.
    Choose-Source ([int]$s['changes.agents'] + 1) 'Uncommitted'
    $s = Await-State @{
        'changes.scope' = 'uncommitted'; 'changes.files' = 3; 'changes.dropdown_open' = 'false'
        'changes.settled' = 'true'; 'changes.file.0.path' = 'a.txt'; 'changes.file.2.path' = 'c.txt'
    } 'Uncommitted shows a.txt, b.txt and c.txt'
    Equal $s['changes.file.0.path'] 'a.txt' 'a.txt is modified'
    Equal $s['changes.file.1.path'] 'b.txt' 'b.txt is deleted'
    Equal $s['changes.file.2.path'] 'c.txt' 'c.txt is untracked'

    Aio capture --out "$data/agent-changes.png" | Out-Null

    # (a) A third turn in the first pane: the agent started in the main folder adds a worktree beside the
    # repository and edits a file there. The turn lists that file, and the git scopes follow the agent.
    Set-Content -LiteralPath $go3 -Value 'x'
    Await-File $finished3 'the agent finished its third turn' | Out-Null
    Await-AtLeast 'turns.saved' 3 'the third turn is saved'
    Equal (State)['turns.last_error'] '' 'the worktree turn records no error'
    # Closing the pane and opening another shows the agent scope on its newest turn, as the first open did.
    Close-Changes 1
    $s = Open-Changes $agentPane 'a new pane opens on the agent scope'
    $s = Await-State @{
        'changes.turns' = 3; 'changes.first' = 0; 'changes.last' = 0; 'changes.files' = 1
        'changes.file.0.path' = 'a.txt'; 'changes.settled' = 'true'
    } 'the worktree turn lists the file the agent edited in the linked worktree'
    Equal $s['changes.file.0.added'] 1 'the worktree edit shows its own line'
    Equal $s['changes.file.0.ambiguous'] false 'the only open turn owns the worktree edit'
    Choose-Source ([int]$s['changes.agents'] + 1) 'Uncommitted again'
    $s = Await-State @{
        'changes.scope' = 'uncommitted'; 'changes.following' = 'true'; 'changes.worktree' = $wtAPath
        'changes.dropdown_open' = 'false'; 'changes.files' = 1; 'changes.settled' = 'true'
        'changes.file.0.path' = 'a.txt'
    } 'Uncommitted follows the agent to the worktree it changed'
    Equal $s['changes.worktrees'] 2 'the picker lists the main worktree and the new one'
    Equal $s['changes.file.0.path'] 'a.txt' 'the followed worktree lists its modified file'
    Aio capture --out "$data/agent-worktree.png" | Out-Null
    # The panel lists Follow the agent, the followed worktree, then the folder's own.
    $s = Open-Panel
    Like $s['changes.worktree_chip.0.label'] '*Follow*' 'the first worktree chip follows the agent'
    Click-Rect $s 'changes.worktree_chip.2.rect'
    Await-State @{ 'changes.following' = 'false'; 'changes.worktree' = $workPath; 'changes.panel_open' = 'true' } `
        'the worktree chip switches back to the main worktree and the panel stays open' | Out-Null
    Close-Panel | Out-Null
    $s = Await-State @{
        'changes.following' = 'false'; 'changes.worktree' = $workPath; 'changes.dropdown_open' = 'false'
        'changes.files' = 3; 'changes.settled' = 'true'; 'changes.file.0.path' = 'a.txt'
        'changes.file.2.path' = 'c.txt'
    } 'the picker switches back to the main worktree'
    Equal $s['changes.file.0.path'] 'a.txt' 'the main worktree lists a.txt'
    Equal $s['changes.file.2.path'] 'c.txt' 'the main worktree lists c.txt'

    # (b) Two agents in parallel, each started from its own worktree, with overlapping turns.
    Set-Content -LiteralPath $worker -Value (@('param($Target, $Name, $Mine, $Other)') + $report + @(
        '$Host.UI.RawUI.WindowTitle = "Worker $Name"'
        "Report 'working' ''"
        # Both turns are open before either edits, so the edits overlap both turns.
        "Set-Content -LiteralPath (`$Mine + '.started') -Value 'x'"
        "while (-not (Test-Path -LiteralPath (`$Other + '.started'))) { Start-Sleep -Milliseconds 100 }"
        'Start-Sleep -Milliseconds 500'
        'Set-Content -LiteralPath (Join-Path $Target $Name) -Value @("from", $Name)'
        "Set-Content -LiteralPath `$Mine -Value 'x'"
        'while (-not (Test-Path -LiteralPath $Other)) { Start-Sleep -Milliseconds 100 }'
        'Start-Sleep -Seconds 1'
        "Report 'done' 'Parallel'"
        'Start-Sleep -Seconds 900'
    ))
    Git worktree add $wtB -b agent-b
    $saved = [int](State)['turns.saved']
    $panes = Start-Pair 2 'b' $wtA $wtB $wtA $wtB 'pa.txt' 'pb.txt'
    Await-AtLeast 'turns.saved' ($saved + 2) 'both worktree agents saved their turns' 40
    Equal (State)['turns.last_error'] '' 'the parallel turns record no error'
    # One Agent changes pane per agent, both in this tab, each showing only its own agent.
    $s = Open-Changes $panes[0] 'the first worktree agent opens the agent scope'
    $s = Await-State @{
        'changes.turns' = 1; 'changes.first' = 0; 'changes.last' = 0; 'changes.files' = 1
        'changes.file.0.path' = 'pa.txt'; 'changes.settled' = 'true'
    } 'the first agent lists only its own worktree file'
    Equal $s['changes.file.0.ambiguous'] false 'the first agent file is not ambiguous'
    Equal $s['changes.file.0.marked'] false 'the first agent file is not marked'
    $changesA = $s['panes.focused']
    Aio capture --out "$data/agent-parallel-worktrees.png" | Out-Null
    $s = Open-Changes $panes[1] 'the second worktree agent opens the agent scope'
    $s = Await-State @{
        'panes.count' = 4; 'changes.turns' = 1; 'changes.first' = 0; 'changes.last' = 0; 'changes.files' = 1
        'changes.file.0.path' = 'pb.txt'; 'changes.settled' = 'true'
    } 'a second Agent changes pane in the tab lists only the second agent file'
    Equal $s['changes.file.0.ambiguous'] false 'the second agent file is not ambiguous'
    Equal $s['changes.file.0.marked'] false 'the second agent file is not marked'
    $changesB = $s['panes.focused']
    Focus-Pane $changesA
    $s = Await-State @{
        'changes.scope' = 'agent'; 'changes.turns' = 1; 'changes.files' = 1; 'changes.file.0.path' = 'pa.txt'
        'changes.settled' = 'true'
    } 'the first pane still shows only the first agent'
    Like $s['changes.agent'] '*pa.txt*' "the first pane's source field names the first worker"

    # The source dropdown switches the first pane to the other agent, to All agents, and back.
    $other = Agent-Index $s 'pb.txt'
    Choose-Source $other 'the second agent'
    $s = Await-State @{
        'changes.dropdown_open' = 'false'; 'changes.scope' = 'agent'; 'changes.turns' = 1; 'changes.files' = 1
        'changes.file.0.path' = 'pb.txt'; 'changes.settled' = 'true'
    } 'the source dropdown switches the pane to the second agent'
    Like $s['changes.agent'] '*pb.txt*' 'the source field names the agent picked'
    Choose-Source ([int]$s['changes.agents']) 'All agents'
    # The first agent's three turns and both workers' turns. Which worker finished last is a race, so only
    # a single selected turn is checked.
    $s = Await-State @{ 'changes.dropdown_open' = 'false'; 'changes.scope' = 'repository'; 'changes.settled' = 'true' } `
        'the source dropdown switches the pane to All agents'
    if ([int]$s['changes.turns'] -lt 5) { throw "All agents expected at least 5 turns, observed $($s['changes.turns'])" }
    Write-Output 'PASS All agents lists every agent turn in the repository'
    if ([int]$s['changes.first'] -lt 0 -or $s['changes.first'] -ne $s['changes.last']) {
        throw "All agents expected one selected turn, observed $($s['changes.first'])..$($s['changes.last'])"
    }
    Write-Output 'PASS All agents keeps one turn selected'
    Choose-Source (Agent-Index $s 'pa.txt') 'the first agent again'
    $s = Await-State @{
        'changes.dropdown_open' = 'false'; 'changes.scope' = 'agent'; 'changes.turns' = 1
        'changes.file.0.path' = 'pa.txt'; 'changes.settled' = 'true'
    } 'the source dropdown switches the pane back to the first agent'
    # Run from an Agent changes pane, the command opens another on that pane's agent and scope. Four panes
    # fill this window's width, so the new pane opens in a new tab, as any split without room does.
    $count = [int]$s['changes.count']
    Aio command pane.agent_changes | Out-Null
    $s = Await-State @{
        'changes.count' = $count + 1; 'changes.active' = 'true'; 'changes.scope' = 'agent'
        'changes.loaded' = 'true'; 'changes.turns' = 1; 'changes.file.0.path' = 'pa.txt'; 'changes.settled' = 'true'
    } 'a run from an Agent changes pane opens another on its agent'
    # Closing it leaves the tab of the four panes, whichever way it opened.
    Close-Changes 4
    Await-State @{ 'tabs.count' = 2; 'tabs.selected' = 2 } 'the tab of the four panes shows again' | Out-Null

    # Moved to a new tab, the second pane keeps following its agent.
    Focus-Pane $changesB
    Aio command pane.move_new_tab | Out-Null
    $s = Await-State @{ 'tabs.count' = 3; 'panes.count' = 1; 'changes.active' = 'true' } `
        'the Agent changes pane moves to a new tab'
    $s = Await-State @{
        'changes.scope' = 'agent'; 'changes.turns' = 1; 'changes.files' = 1; 'changes.file.0.path' = 'pb.txt'
        'changes.settled' = 'true'
    } 'the moved pane still shows the second agent'
    Like $s['changes.agent'] '*pb.txt*' 'the moved pane keeps its agent'
    # The tab's only pane closes the tab.
    Aio command pane.close | Out-Null
    Await-State @{ 'tabs.count' = 2; 'tabs.selected' = 2; 'panes.count' = 3 } `
        'closing the moved pane closes its tab' | Out-Null
    Focus-Pane $changesA
    Close-Changes 2

    # (c) Two agents in parallel, both started in the main folder, edit the two worktrees. Neither is
    # linked to either worktree, so each turn takes both files and marks them as possibly the other's.
    $saved = [int](State)['turns.saved']
    $panes = Start-Pair 3 'c' $work $work $wtA $wtB 'ca.txt' 'cb.txt'
    Await-AtLeast 'turns.saved' ($saved + 2) 'both shared-worktree agents saved their turns' 40
    Equal (State)['turns.last_error'] '' 'the shared turns record no error'
    foreach ($node in $panes) {
        $s = Open-Changes $node "the agent started in the main folder opens the agent scope ($node)"
        # A diff spanning two worktrees labels each path with its worktree's folder.
        $s = Await-State @{
            'changes.turns' = 1; 'changes.first' = 0; 'changes.last' = 0; 'changes.files' = 2
            'changes.file.0.path' = "$(Split-Path -Leaf $wtA)/ca.txt"
            'changes.file.1.path' = "$(Split-Path -Leaf $wtB)/cb.txt"; 'changes.settled' = 'true'
        } "the newest turn lists both worktree files ($node)"
        Equal $s['changes.file.0.ambiguous'] true "ca.txt may include another agent's changes ($node)"
        Equal $s['changes.file.1.ambiguous'] true "cb.txt may include another agent's changes ($node)"
        # The other agent's copy of the same shared change is not an outside change.
        Equal $s['changes.file.0.marked'] false "ca.txt is not also marked as changed outside ($node)"
        Equal $s['changes.file.1.marked'] false "cb.txt is not also marked as changed outside ($node)"
        if ($node -eq $panes[0]) {
            Aio capture --out "$data/agent-shared-worktrees.png" | Out-Null
            # The file list shows the worktree folder of each path, shortened from its start, and the marks.
            Open-Files | Out-Null
            Aio capture --out "$data/agent-row-files-worktree.png" | Out-Null
            Aio key Esc | Out-Null
            Await-State @{ 'changes.files_open' = 'false' } 'Esc closes the file list' | Out-Null
        }
        Close-Changes 2
    }

    # (d) A reviewing agent in the main folder: its open turn shows live, then its comments go back to it.
    # After its turn it turns bracketed paste on, as a coding agent's prompt does, and echoes each line it
    # reads until EXIT; it reads keys rather than lines so the paste brackets cannot clear a line. Send
    # pastes only into the program that reports, so it names its own executable, pwsh, as its app.
    $reviewer = "$data/reviewer.ps1"
    $reviewStarted = "$data/review-started.flag"
    $reviewGo = "$data/review-go.flag"
    $reviewEnd = "$data/review-end.flag"
    $reviewReady = "$data/review-ready.flag"
    Set-Content -LiteralPath $reviewer -Value (@(
        "`$work = '$work'"
        "`$started = '$reviewStarted'"
        "`$go = '$reviewGo'"
        "`$end = '$reviewEnd'"
        "`$ready = '$reviewReady'"
    ) + ($report -replace 'app=claude', 'app=pwsh') + @(
        '$Host.UI.RawUI.WindowTitle = ''Reviewer agent'''
        "Report 'working' ''"
        "Set-Content -LiteralPath `$started -Value 'x'"
        'while (-not (Test-Path -LiteralPath $go)) { Start-Sleep -Milliseconds 100 }'
        'Set-Content -LiteralPath (Join-Path $work ''live.py'') -Value @('
        '    ''# A live turn'''
        '    ''def greet(name):'''
        '    ''    return "hello " + name'''
        '    ''VALUE = 42'''
        ')'
        # Long enough to scroll, so the file list can put the header of a later file at the top.
        'Set-Content -LiteralPath (Join-Path $work ''long.txt'') -Value (1..200 | ForEach-Object { "line $_" })'
        "Set-Content -LiteralPath (Join-Path `$work 'notes.txt') -Value @('alpha', '$wideNew', 'gamma', 'delta')"
        # Sorts last, with no t in its path, and keeps enough below long.txt to scroll it to the top.
        'Set-Content -LiteralPath (Join-Path $work ''zz.md'') -Value (1..150 | ForEach-Object { "- entry $_" })'
        'while (-not (Test-Path -LiteralPath $end)) { Start-Sleep -Milliseconds 100 }'
        "Report 'done' 'Live'"
        '[Console]::Write([char]27 + ''[?2004h'')'
        "Set-Content -LiteralPath `$ready -Value 'x'"
        '$line = '''''
        'while ($true) {'
        '    $c = $Host.UI.RawUI.ReadKey(''NoEcho,IncludeKeyDown'').Character'
        '    if ($c -eq [char]13 -or $c -eq [char]10) {'
        '        if ($line -eq ''EXIT'') { break }'
        '        [Console]::WriteLine(''ECHO:'' + $line)'
        '        $line = '''''
        '    } elseif ([int]$c -ge 32) { $line += $c }'
        '}'
        '[Console]::Write([char]27 + ''[?2004l'')'
        '[Console]::WriteLine(''REVIEWER_DONE'')'
    ))
    Aio command tab.new | Out-Null
    Await-State @{ 'tabs.count' = 4; 'tabs.selected' = 4 } 'tab 4 opens' | Out-Null
    Aio wait text 'PS ' | Out-Null
    $reviewPane = (State)['panes.focused']
    Aio run "cd '$work'; Write-Output ('READY_' + 'review')" | Out-Null
    Aio wait text 'READY_review' | Out-Null
    $saved = [int](State)['turns.saved']
    Aio run "pwsh -NoProfile -File '$reviewer'" | Out-Null
    Await-File $reviewStarted 'the reviewer began its turn' | Out-Null
    $s = Open-Changes $reviewPane 'the reviewer opens the agent scope'
    # An open turn with no file written is not listed, so the pane has no turns yet.
    $s = Await-State @{
        'changes.turns' = 0; 'changes.turn.0.live' = ''; 'changes.notice' = 'no_turns'; 'changes.settled' = 'true'
    } 'an open turn with no file is not listed'
    $reviewChanges = $s['panes.focused']
    Like $s['changes.agent'] '*Reviewer agent*' 'the source field names the reviewer'
    Set-Content -LiteralPath $reviewGo -Value 'x'
    # The turn is listed, selected and live, once its first file is written.
    $s = Await-State @{
        'changes.turns' = 1; 'changes.turn.0.live' = 'true'; 'changes.first' = 0; 'changes.last' = 0
    } 'the open turn is a live row, selected, once it has written a file' 5
    Await-Like 'changes.range_label' 'Working*' 'the range label says the live turn is working' | Out-Null
    # Paths sort, so live.py comes first, then long.txt, notes.txt and zz.md.
    # The files must show within 3 s of the writes. A later live refresh may still be in flight then, so the
    # view settling is waited for separately.
    $s = Await-State @{
        'changes.turn.0.live' = 'true'; 'changes.files' = 4; 'changes.file.0.path' = 'live.py'
        'changes.file.1.path' = 'long.txt'; 'changes.file.2.path' = 'notes.txt'; 'changes.file.3.path' = 'zz.md'
    } 'the live turn lists the files the agent wrote within 3 s' 3
    $s = Await-State @{ 'changes.settled' = 'true'; 'changes.files' = 4 } 'the live view settles'
    Set-Content -LiteralPath $reviewEnd -Value 'x'
    Await-AtLeast 'turns.saved' ($saved + 1) 'the live turn is saved at its end' | Out-Null
    $s = Await-State @{
        'changes.turns' = 1; 'changes.turn.0.live' = 'false'; 'changes.first' = 0; 'changes.last' = 0
        'changes.files' = 4; 'changes.file.0.path' = 'live.py'; 'changes.file.0.highlighted' = 'true'
        'changes.settled' = 'true'
    } 'the saved turn keeps its selection and highlights live.py'
    Equal $s['changes.file.0.added'] 4 'live.py adds its four lines'
    Aio capture --out "$data/agent-live-highlight.png" | Out-Null

    # (f) The header row: a wide pane keeps every control and the panel stays closed until asked.
    $s = State
    Equal $s['changes.row_steps'] 0 'a wide pane takes no collapse step'
    foreach ($key in 'changes.row_rect', 'changes.summary_rect', 'changes.files_button_rect',
        'changes.layout_button_rect', 'changes.fold_button_rect', 'changes.filter_button_rect') { Assert-Shown $s $key }
    foreach ($key in 'changes.tools_button_rect', 'changes.panel_rect', 'changes.step_back_rect',
        'changes.step_forward_rect', 'changes.range_label_rect', 'changes.strip.0.rect') { Assert-Hidden $s $key }
    Equal $s['changes.panel_open'] false 'the panel is closed'
    Equal $s['changes.tools_open'] false 'the tools menu is closed'
    Assert-Hidden $s 'changes.source_chip.0.rect'
    Aio capture --out "$data/agent-row.png" | Out-Null
    # At 150% the row's icons and the files button's still share one centre line; the capture is checked by eye.
    Aio dpi 144 | Out-Null
    Start-Sleep -Milliseconds 800
    Aio capture --out "$data/agent-row-144.png" | Out-Null
    Aio dpi 96 | Out-Null
    Await-State @{ 'changes.row_steps' = '0' } 'the row goes back to 100%' | Out-Null
    $s = State
    # The summary opens the panel, with no file list; a second click, outside the panel, closes it.
    Click-Rect $s 'changes.summary_rect'
    $s = Await-State @{ 'changes.panel_open' = 'true'; 'changes.dropdown_open' = 'false' } 'the summary opens the panel without a file list'
    Assert-Shown $s 'changes.panel_rect'
    Assert-Shown $s 'changes.strip.0.rect'
    Assert-Shown $s 'changes.range_label_rect'
    # Source chips: the agents, then All agents, Uncommitted, Staged and Unstaged changes.
    $agents = [int]$s['changes.agents']
    for ($i = 0; $i -lt $agents; $i++) {
        Assert-Shown $s "changes.source_chip.$i.rect"
        Equal $s["changes.source_chip.$i.label"] $s["changes.agent.$i.label"] "source chip $i is its agent"
    }
    Like $s["changes.source_chip.$agents.label"] 'All agents*' 'the chip after the agents is All agents'
    Like $s["changes.source_chip.$($agents + 1).label"] 'Uncommitted*' 'the next chip is Uncommitted changes'
    Like $s["changes.source_chip.$($agents + 2).label"] 'Staged*' 'the next chip is Staged changes'
    Like $s["changes.source_chip.$($agents + 3).label"] 'Unstaged*' 'the last chip is Unstaged changes'
    Equal $s["changes.source_chip.$($agents + 4).rect"] '' 'no chip follows Unstaged changes'
    Equal $s['changes.source_chip_current'] (Agent-Index $s 'Reviewer agent') 'the current chip is the reviewer agent'
    Equal $s['changes.worktree_chip.0.rect'] '' 'the agent scope has no worktree chips'
    Aio capture --out "$data/agent-row-panel.png" | Out-Null
    Click-Rect $s 'changes.summary_rect'
    Await-State @{ 'changes.panel_open' = 'false'; 'changes.dropdown_open' = 'false' } 'a second click on the summary closes the panel' | Out-Null
    Aio key Ctrl+K | Out-Null
    Await-State @{ 'changes.panel_open' = 'true'; 'changes.dropdown_open' = 'false' } 'Ctrl+K opens the panel' | Out-Null
    Close-Panel | Out-Null
    $s = State
    Click-Rect $s 'changes.summary_rect'
    $s = Await-State @{ 'changes.panel_open' = 'true' } 'the summary opens the panel'
    # A press outside the panel and its list closes both and does nothing else, here selecting no line.
    $pane = Rect $s "pane.$reviewChanges.rect"
    $selection = $s['changes.selection']
    Aio mouse click "$([int]($pane[0] + $pane[2] / 2)),$([int]($pane[1] + $pane[3] - 30))" --px | Out-Null
    $s = Await-State @{ 'changes.panel_open' = 'false'; 'changes.dropdown_open' = 'false' } 'a press outside the panel closes it and its list'
    Equal $s['changes.selection'] $selection 'the closing press selects nothing'

    # The overview strip replaces the scrollbar and is one: its thumb marks the part on screen like the
    # shared scrollbar's, a press on its track pages toward the pointer and a held one keeps paging until the
    # thumb reaches it, and the thumb drags by where it was grabbed.
    Assert-Shown $s 'changes.overview_rect'
    Assert-Shown $s 'changes.overview_thumb_rect'
    $lane = Rect $s 'changes.overview_rect'
    $laneX = [int]($lane[0] + $lane[2] / 2)
    $thumb = Rect $s 'changes.overview_thumb_rect'
    if ($thumb[3] -lt 20) { throw "the overview thumb is too small to grab: $($thumb -join ',')" }
    Write-Output "PASS the overview thumb is $([int]$thumb[3]) px tall and $([int]$thumb[2]) px wide"
    Aio mouse move "$($laneX - 200),$([int]($lane[1] + $lane[3] / 2))" --px | Out-Null
    Await-State @{ 'changes.overview_state' = 'rest' } 'the overview thumb is at rest while the pointer is elsewhere' | Out-Null
    Aio mouse move "$laneX,$([int]($lane[1] + $lane[3] - 4))" --px | Out-Null
    Await-State @{ 'changes.overview_state' = 'hover' } 'the overview thumb highlights under the pointer' | Out-Null
    # A click on the track pages once toward the pointer, and releasing it ends the paging.
    $scroll = [double](State)['changes.diff_scroll']
    Aio mouse click "$laneX,$([int]($lane[1] + $lane[3] * 0.9))" --px | Out-Null
    Await-AtLeast 'changes.diff_scroll' ($scroll + 1) 'pressing the lower overview track pages the diff down' | Out-Null
    $paged = [double](State)['changes.diff_scroll']
    $page = $paged - $scroll
    Start-Sleep -Milliseconds 700
    Equal ([double](State)['changes.diff_scroll']) $paged 'a click on the overview track pages once and stops'
    # Holding it pages again after the delay and keeps going until the thumb is under the pointer.
    $pointerY = [int]($lane[1] + $lane[3] * 0.85)
    Aio mouse down "$laneX,$pointerY" --px | Out-Null
    $deadline = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 100
        $s = State
        $thumb = Rect $s 'changes.overview_thumb_rect'
        $met = $thumb[1] -le $pointerY -and $pointerY -lt $thumb[1] + $thumb[3]
    } until ($met -or (Get-Date) -ge $deadline)
    if (-not $met) { throw "the held overview press never reached the pointer: thumb $($thumb -join ',') pointer $pointerY" }
    $held = [double]$s['changes.diff_scroll']
    if ($held -lt $paged + 2 * $page - 1) { throw "holding paged less than twice more: $paged -> $held (page $page)" }
    Write-Output "PASS holding the overview track pages repeatedly ($paged -> $held, a page is $page) until the thumb reaches the pointer"
    Start-Sleep -Milliseconds 500
    Equal ([double](State)['changes.diff_scroll']) $held 'the held press stops paging once the thumb is under the pointer'
    # As on a native scrollbar, the press repeats only toward the side it began on. The pointer crossing to the
    # other side of the thumb pauses it rather than reversing it, leaving the track pauses it too, and back on
    # its side, ahead of the thumb, it resumes.
    Aio mouse move "$laneX,$([int]($lane[1] + 4))" --px | Out-Null
    Start-Sleep -Milliseconds 700
    Equal ([double](State)['changes.diff_scroll']) $held 'the held press pauses, not reverses, across the thumb'
    Aio mouse move "$($laneX - 200),$([int]($lane[1] + $lane[3] - 3))" --px | Out-Null
    Start-Sleep -Milliseconds 700
    Equal ([double](State)['changes.diff_scroll']) $held 'the held press pauses off the track'
    Aio mouse move "$laneX,$([int]($lane[1] + $lane[3] - 3))" --px | Out-Null
    Await-AtLeast 'changes.diff_scroll' ($held + 1) 'the held press resumes when the pointer is back ahead of the thumb' | Out-Null
    Aio mouse up "$laneX,$([int]($lane[1] + $lane[3] - 3))" --px | Out-Null
    # The thumb drags by where it was grabbed, so the view does not jump under the pointer.
    Aio mouse move "$laneX,$([int]($lane[1] + 4))" --px | Out-Null
    $s = State
    $thumb = Rect $s 'changes.overview_thumb_rect'
    Aio mouse down "$laneX,$([int]($thumb[1] + 6))" --px | Out-Null
    Aio mouse move "$laneX,$([int]($thumb[1] + 6 - 120))" --px | Out-Null
    $s = Await-State @{ 'changes.overview_state' = 'drag' } 'the overview thumb is held while it is dragged'
    $moved = Rect $s 'changes.overview_thumb_rect'
    if ([Math]::Abs(($moved[1] - $thumb[1]) + 120) -gt 4) { throw "the dragged thumb did not follow by 120 px up: $($thumb[1]) -> $($moved[1])" }
    Write-Output "PASS the dragged overview thumb moves by the pointer's distance and keeps its grab ($($thumb[1]) -> $($moved[1]))"
    Aio mouse up "$laneX,$([int]($thumb[1] + 6 - 120))" --px | Out-Null
    # Holding the top of the lane pages to the top of the diff.
    Aio mouse down "$laneX,$([int]($lane[1] + 2))" --px | Out-Null
    Await-State @{ 'changes.diff_scroll' = '0' } 'holding the top of the overview scrolls to the top' | Out-Null
    Aio mouse up "$laneX,$([int]($lane[1] + 2))" --px | Out-Null

    # (g) Narrowing the window narrows the pane: the row collapses its buttons into one tools button first.
    $narrow = $null
    foreach ($cols in 110, 96, 84, 72, 62, 52) {
        Resize-Window $cols
        $s = State
        if ([int]$s['changes.row_steps'] -ge 1) { $narrow = $cols; break }
    }
    if (-not $narrow) { throw "narrowing expected row_steps >= 1, observed $($s['changes.row_steps'])" }
    Write-Output "PASS the row collapses at $narrow columns (step $($s['changes.row_steps']))"
    Assert-Shown $s 'changes.tools_button_rect'
    foreach ($key in 'changes.layout_button_rect', 'changes.fold_button_rect', 'changes.filter_button_rect') { Assert-Hidden $s $key }
    Assert-Shown $s 'changes.files_button_rect'
    Aio capture --out "$data/agent-row-narrow.png" | Out-Null
    # The tools menu: Side-by-side, Collapse all files, Filter files.
    Click-Rect $s 'changes.tools_button_rect'
    $s = Await-State @{ 'changes.tools_open' = 'true' } 'the tools button opens its menu'
    foreach ($i in 0..2) { Assert-Shown $s "changes.tools_row.$i.rect" }
    Aio capture --out "$data/agent-row-menu.png" | Out-Null
    Click-Rect $s 'changes.tools_row.0.rect'
    $s = Await-State @{ 'changes.tools_open' = 'false'; 'changes.side_by_side' = 'true' } 'the Side-by-side row toggles the layout and closes the menu'
    Click-Rect $s 'changes.tools_button_rect'
    $s = Await-State @{ 'changes.tools_open' = 'true' } 'the menu opens again'
    Click-Rect $s 'changes.tools_row.0.rect'
    $s = Await-State @{ 'changes.tools_open' = 'false'; 'changes.side_by_side' = 'false' } 'the Side-by-side row toggles back'
    Click-Rect $s 'changes.tools_button_rect'
    $s = Await-State @{ 'changes.tools_open' = 'true' } 'the menu opens for the fold row'
    Click-Rect $s 'changes.tools_row.1.rect'
    $s = Await-State @{ 'changes.tools_open' = 'false'; 'changes.any_expanded' = 'false' } 'the fold row collapses every file'
    Click-Rect $s 'changes.tools_button_rect'
    $s = Await-State @{ 'changes.tools_open' = 'true' } 'the menu opens to expand'
    Click-Rect $s 'changes.tools_row.1.rect'
    Await-State @{ 'changes.tools_open' = 'false'; 'changes.any_expanded' = 'true' } 'the fold row expands every file again' | Out-Null
    $s = State
    Click-Rect $s 'changes.tools_button_rect'
    $s = Await-State @{ 'changes.tools_open' = 'true' } 'the menu opens for the filter row'
    Click-Rect $s 'changes.tools_row.2.rect'
    Await-State @{ 'changes.tools_open' = 'false'; 'changes.filter_open' = 'true' } 'the Filter files row closes the menu and opens the filter popover' | Out-Null
    Aio key Esc | Out-Null
    $s = Await-State @{ 'changes.filter_open' = 'false' } 'Escape closes the filter popover'
    # Escape or a press outside closes the menu.
    Click-Rect $s 'changes.tools_button_rect'
    Await-State @{ 'changes.tools_open' = 'true' } 'the menu opens for Escape' | Out-Null
    Aio key Esc | Out-Null
    $s = Await-State @{ 'changes.tools_open' = 'false' } 'Escape closes the menu'
    Click-Rect $s 'changes.tools_button_rect'
    Await-State @{ 'changes.tools_open' = 'true' } 'the menu opens for an outside press' | Out-Null
    $pane = Rect $s "pane.$reviewChanges.rect"
    Aio mouse click "$([int]($pane[0] + $pane[2] / 2)),$([int]($pane[1] + $pane[3] - 30))" --px | Out-Null
    Await-State @{ 'changes.tools_open' = 'false' } 'a press outside closes the menu' | Out-Null
    # The panel fits the narrow pane.
    Aio key Ctrl+K | Out-Null
    $s = Await-State @{ 'changes.panel_open' = 'true' } 'Ctrl+K opens the panel in the narrow pane'
    $pane = Rect $s "pane.$reviewChanges.rect"
    $panel = Rect $s 'changes.panel_rect'
    if ($panel[0] -lt $pane[0] -or $panel[0] + $panel[2] -gt $pane[0] + $pane[2]) {
        throw "the panel expected inside the pane $($pane -join ','), observed $($panel -join ',')"
    }
    Write-Output 'PASS the panel stays inside the narrow pane'
    Aio capture --out "$data/agent-row-narrow-panel.png" | Out-Null
    Close-Panel | Out-Null
    # Narrower still, the row takes further steps and never un-collapses.
    $last = [int](State)['changes.row_steps']
    foreach ($cols in 52, 44, 38) {
        Resize-Window $cols
        Start-Sleep -Milliseconds 600
        $now = [int](State)['changes.row_steps']
        if ($now -lt $last) { throw "row_steps expected >= $last at $cols columns, observed $now" }
        $last = $now
    }
    Write-Output "PASS the row reaches step $last at 38 columns without un-collapsing"
    Resize-Window 150
    Await-State @{ 'changes.row_steps' = '0' } 'the wide window restores the whole row' | Out-Null

    # The file list: typing part of a later file's path and Enter puts that file's header at the top.
    Open-Files | Out-Null
    Aio capture --out "$data/agent-row-files.png" | Out-Null
    Aio type 'long' | Out-Null
    Await-Like 'changes.file_list.0.label' '*long.txt*' 'the search keeps long.txt' | Out-Null
    Aio key Enter | Out-Null
    $s = Await-State @{ 'changes.files_open' = 'false'; 'changes.panel_open' = 'false'; 'changes.top_file' = 1 } `
        'picking long.txt scrolls its header to the top'
    # Side by side keeps the top file in view; a modified file shows its old line left of its new one.
    Click-Rect $s 'changes.layout_button_rect'
    $s = Await-State @{ 'changes.side_by_side' = 'true'; 'changes.top_file' = 1 } `
        'the layout toggle shows the diff side by side'
    Open-Files | Out-Null
    Aio type 'notes' | Out-Null
    Await-Like 'changes.file_list.0.label' '*notes.txt*' 'the search keeps notes.txt' | Out-Null
    Aio key Enter | Out-Null
    $s = Await-State @{ 'changes.files_open' = 'false'; 'changes.panel_open' = 'false'; 'changes.side_by_side' = 'true' } 'picking notes.txt closes the list and the panel'
    Aio capture --out "$data/agent-side-by-side.png" | Out-Null
    # notes.txt: alpha, -beta, +BETA, gamma, delta; the removed and the added line share a row.
    $old = Rect $s 'changes.line.2.1.rect'
    $new = Rect $s 'changes.line.2.2.rect'
    if (-not ($old[2] -gt 0 -and $new[2] -gt 0 -and $new[0] -gt $old[0] -and $new[1] -eq $old[1])) {
        throw "side by side expected beta left of BETA on one row, observed $($old -join ',') and $($new -join ',')"
    }
    Write-Output 'PASS the removed and added lines share a row, old on the left'
    Click-Rect $s 'changes.line.2.2.rect' --mods Alt
    Await-State @{ 'changes.selection' = '2:2-2'; 'changes.selection_mode' = 'lines' } 'an Alt+click on a right-half line selects the new line' | Out-Null
    # Back to unified, with live.py at the top again for the comments below.
    $s = State
    Open-Files | Out-Null
    Aio type 'live' | Out-Null
    Await-Like 'changes.file_list.0.label' '*live.py*' 'the search keeps live.py' | Out-Null
    Aio key Enter | Out-Null
    $s = Await-State @{ 'changes.files_open' = 'false'; 'changes.panel_open' = 'false'; 'changes.top_file' = 0 } 'picking live.py scrolls to the top'
    Click-Rect $s 'changes.layout_button_rect'
    $s = Await-State @{ 'changes.side_by_side' = 'false'; 'changes.top_file' = 0 } 'the layout toggle goes back to unified'

    # The file list's search takes a regular expression with its .* toggle; an invalid one matches nothing.
    Open-Files | Out-Null
    $s = Await-State @{ 'changes.files_open' = 'true'; 'changes.file_list_regex' = 'false' } `
        'the file list opens with plain search'
    Click-Rect $s 'changes.file_list_regex_rect'
    Await-State @{ 'changes.file_list_regex' = 'true' } 'the .* toggle turns regular expressions on' | Out-Null
    Aio type '^l.*\.py$' | Out-Null
    $s = Await-State @{ 'changes.file_list.1.label' = ''; 'changes.file_list_empty' = '' } `
        'the regular expression leaves one file'
    Like $s['changes.file_list.0.label'] '*live.py*' 'the regular expression matches live.py only'
    Aio key Ctrl+A Backspace | Out-Null
    Aio type '[' | Out-Null
    Await-State @{ 'changes.file_list_empty' = 'Invalid regular expression'; 'changes.file_list.0.label' = '' } `
        'an invalid regular expression lists nothing and says why' | Out-Null
    Aio key Esc | Out-Null
    Await-State @{ 'changes.files_open' = 'false'; 'changes.panel_open' = 'false' } 'Esc closes the file list and the panel' | Out-Null

    # The diff filter hides files whose path a !term matches; the file list keeps them, faded. Filter edits
    # refill the view from the result in memory, so the waits are on the filter keys and the paths.
    $s = State
    Click-Rect $s 'changes.filter_button_rect'
    Await-State @{ 'changes.filter_open' = 'true' } 'the filter button opens the filter' | Out-Null
    Aio type '!long' | Out-Null
    # Lines: live.py +4, long.txt +200, notes.txt +1 -1, zz.md +150.
    $s = Await-State @{
        'changes.filter' = '!long'; 'changes.filter_active' = 'true'; 'changes.hidden_files' = 1
        'changes.total_files' = 4; 'changes.files' = 3; 'changes.file.0.path' = 'live.py'
        'changes.file.1.path' = 'notes.txt'; 'changes.file.2.path' = 'zz.md'
        'changes.shown_added' = 155; 'changes.shown_removed' = 1; 'changes.total_added' = 355
        'changes.total_removed' = 1
    } '!long hides long.txt and its lines from the shown totals'
    Aio capture --out "$data/agent-filter.png" | Out-Null
    Aio key Enter | Out-Null
    $s = Await-State @{ 'changes.filter_open' = 'false'; 'changes.filter' = '!long'; 'changes.files' = 3 } `
        'Enter closes the filter and keeps it'
    Open-Files | Out-Null
    $s = Await-State @{
        'changes.files_open' = 'true'; 'changes.file_list.0.faded' = 'false'; 'changes.file_list.1.faded' = 'true'
        'changes.file_list.2.faded' = 'false'; 'changes.file_list.3.faded' = 'false'
    } 'the file list keeps the hidden file, faded'
    Like $s['changes.file_list.1.label'] '*long.txt*' 'the faded file is long.txt'
    Aio type 'long' | Out-Null
    Await-Like 'changes.file_list.0.label' '*long.txt*' 'the search finds the hidden long.txt' | Out-Null
    Aio key Enter | Out-Null
    $s = Await-State @{
        'changes.files_open' = 'false'; 'changes.filter' = '!long'; 'changes.files' = 4
        'changes.file.1.path' = 'long.txt'; 'changes.top_file' = 1
        'changes.shown_added' = 355; 'changes.shown_removed' = 1; 'changes.total_added' = 355
        'changes.total_removed' = 1
    } 'picking the hidden long.txt shows it and its lines despite the filter'
    # live.py has no t; notes.txt has one but !notes hides it.
    Click-Rect $s 'changes.filter_button_rect'
    Await-State @{ 'changes.filter_open' = 'true' } 'the filter opens again' | Out-Null
    Aio key Ctrl+A Backspace | Out-Null
    Aio type 't !notes' | Out-Null
    Await-State @{
        'changes.filter' = 't !notes'; 'changes.filter_active' = 'true'; 'changes.hidden_files' = 3
        'changes.files' = 1; 'changes.file.0.path' = 'long.txt'
    } 'a plain term and a !term together show only long.txt' | Out-Null
    Aio key Ctrl+A Backspace | Out-Null
    Aio type '[' | Out-Null
    $s = Await-State @{
        'changes.filter' = '['; 'changes.filter_invalid' = 'true'; 'changes.filter_active' = 'false'
        'changes.hidden_files' = 0; 'changes.files' = 4
    } 'an invalid filter hides nothing'
    Like $s['changes.filter_error'] 'Invalid regular expression*' 'the filter says the term is invalid'
    Aio key Ctrl+A Backspace | Out-Null
    Aio type '!long' | Out-Null
    Await-State @{ 'changes.filter' = '!long'; 'changes.hidden_files' = 1; 'changes.files' = 3 } `
        'editing the filter hides long.txt again' | Out-Null
    Aio key Esc | Out-Null
    $s = Await-State @{ 'changes.filter_open' = 'false'; 'changes.filter' = '!long' } 'Esc closes the filter and keeps it'
    Click-Rect $s 'changes.filter_bar_clear_rect'
    $s = Await-State @{
        'changes.filter' = ''; 'changes.filter_active' = 'false'; 'changes.hidden_files' = 0; 'changes.files' = 4
        'changes.file.0.path' = 'live.py'; 'changes.file.1.path' = 'long.txt'; 'changes.file.2.path' = 'notes.txt'
        'changes.file.3.path' = 'zz.md'
        'changes.shown_added' = 355; 'changes.shown_removed' = 1; 'changes.total_added' = 355
        'changes.total_removed' = 1
    } 'Clear on the filter bar shows every file and every line'

    # Sticky header: inside long.txt its header stays pinned at the top of the diff.
    Open-Files | Out-Null
    Aio type 'long' | Out-Null
    Await-Like 'changes.file_list.0.label' '*long.txt*' 'the search finds long.txt' | Out-Null
    Aio key Enter | Out-Null
    $s = Await-State @{ 'changes.files_open' = 'false'; 'changes.panel_open' = 'false'; 'changes.top_file' = 1 } 'picking long.txt puts it at the top'
    # Wheel rows are positive toward the top, so a negative count scrolls down into the file.
    Aio mouse wheel (Middle (Rect $s "pane.$reviewChanges.rect")) -5 --px | Out-Null
    $s = Await-State @{ 'changes.top_file' = 1; 'changes.sticky_file' = 1 } 'the long.txt header sticks inside its body'
    Aio capture --out "$data/agent-sticky.png" | Out-Null
    # Collapsing from the sticky header puts that file's header at the top.
    Click-Rect $s 'changes.sticky_rect'
    $s = Await-State @{ 'changes.file.1.collapsed' = 'true'; 'changes.top_file' = 1; 'changes.sticky_file' = -1 } `
        'pressing the sticky header collapses long.txt and keeps it at the top'
    # Fold all collapses every file while one is expanded, then expands them all.
    Click-Rect $s 'changes.fold_button_rect'
    $s = Await-State @{
        'changes.any_expanded' = 'false'; 'changes.file.0.collapsed' = 'true'; 'changes.file.1.collapsed' = 'true'
        'changes.file.2.collapsed' = 'true'; 'changes.file.3.collapsed' = 'true'
    } 'the fold button collapses every file'
    Click-Rect $s 'changes.fold_button_rect'
    $s = Await-State @{
        'changes.any_expanded' = 'true'; 'changes.file.0.collapsed' = 'false'; 'changes.file.1.collapsed' = 'false'
        'changes.file.2.collapsed' = 'false'; 'changes.file.3.collapsed' = 'false'
    } 'the fold button expands every file again'
    # live.py at the top again for the comments below.
    Open-Files | Out-Null
    Aio type 'live' | Out-Null
    Await-Like 'changes.file_list.0.label' '*live.py*' 'the search finds live.py again' | Out-Null
    Aio key Enter | Out-Null
    $s = Await-State @{ 'changes.files_open' = 'false'; 'changes.panel_open' = 'false'; 'changes.top_file' = 0 } 'picking live.py scrolls back to the top'

    # Tokyo Night Moon draws comments faintly on added rows; the diff raises code text to the minimum contrast.
    $ini = Get-Content -LiteralPath "$data/settings.ini" -Raw
    $theme = (State)['theme.name']
    Add-Content -LiteralPath "$data/settings.ini" -Value "`ntheme.name = tokyonight-moon"
    Aio command settings.reload | Out-Null
    Await-State @{ 'theme.name' = 'tokyonight-moon'; 'changes.minimum_contrast' = '4.5'; 'changes.top_file' = 0 } `
        'Tokyo Night Moon draws the diff at the default minimum contrast' | Out-Null
    Aio capture --out "$data/agent-contrast.png" | Out-Null
    Set-Content -LiteralPath "$data/settings.ini" -Value $ini -NoNewline
    Aio command settings.reload | Out-Null
    Await-State @{ 'theme.name' = $theme } 'the original theme returns' | Out-Null

    # Middle-click scrolling: a Middle press on the diff drops the anchor and the diff scrolls toward the
    # pointer, as a Markdown page does; the overview strip and the pinned header follow it.
    $s = State
    $row = Rect $s 'changes.line.0.1.rect'
    $ax = [int]($row[0] + $row[2] / 2)
    $ay = [int]($row[1] + $row[3] / 2)
    $box = Rect $s 'changes.overview_thumb_rect'
    Aio mouse click "$ax,$ay" --px --button middle | Out-Null
    $s = State
    Equal $s['pointer.shape'] 'resize_vertical' 'a middle click on the diff drops the anchor'
    Equal $s['changes.diff_scroll'] 0 'the click alone does not scroll'
    Equal $s['changes.selection_mode'] '' 'and selects nothing'
    Aio capture --out "$data/agent-anchor.png" | Out-Null
    Aio mouse move "$ax,$($ay + 160)" --px | Out-Null
    Start-Sleep -Milliseconds 700
    $s = State
    $moved = [double]$s['changes.diff_scroll']
    if ($moved -le 0) { throw "below the anchor expected the diff to scroll down, observed $moved" }
    Write-Output "PASS below the anchor the diff scrolls down ($moved)"
    if ([int]$s['changes.top_file'] -lt 1 -or [int]$s['changes.sticky_file'] -lt 0) {
        throw "scrolling expected a later file at the top with a pinned header, observed top $($s['changes.top_file']) sticky $($s['changes.sticky_file'])"
    }
    Write-Output 'PASS the pinned header follows the scroll'
    $moved2 = Rect $s 'changes.overview_thumb_rect'
    if ($moved2[1] -le $box[1]) { throw "the overview box expected to follow the scroll, observed $($moved2[1]) over $($box[1])" }
    Write-Output 'PASS the overview strip follows the scroll'
    Aio capture --out "$data/agent-anchor-scrolling.png" | Out-Null
    Aio mouse move "$ax,$($ay + 4)" --px | Out-Null
    $a = [double](State)['changes.diff_scroll']
    Start-Sleep -Milliseconds 400
    Equal ([double](State)['changes.diff_scroll']) $a 'back in the dead zone it rests'
    Aio mouse move "$ax,$($ay - 160)" --px | Out-Null
    Start-Sleep -Milliseconds 500
    if ([double](State)['changes.diff_scroll'] -ge $a) { throw 'above the anchor expected the diff to scroll up' }
    Write-Output 'PASS above the anchor the diff scrolls up'
    Aio mouse click "$ax,$($ay - 160)" --px | Out-Null
    $a = [double](State)['changes.diff_scroll']
    Start-Sleep -Milliseconds 400
    $s = State
    Equal ([double]$s['changes.diff_scroll']) $a 'a click ends scrolling'
    Equal $s['changes.selection_mode'] '' 'the ending click selects nothing'
    if ($s['pointer.shape'] -eq 'resize_vertical') { throw 'the pointer expected its usual shape after the anchor ended' }
    Write-Output 'PASS the pointer returns to its usual shape'
    # Hold the button: scrolling lasts while it is down and ends on its release.
    Aio mouse wheel "$ax,$ay" 200 --px | Out-Null
    Await-State @{ 'changes.diff_scroll' = '0' } 'the wheel brings the diff back to the top' | Out-Null
    Aio mouse down "$ax,$ay" --px --button middle | Out-Null
    Aio mouse move "$ax,$($ay + 160)" --px --button middle | Out-Null
    Start-Sleep -Milliseconds 500
    Aio mouse up "$ax,$($ay + 160)" --px --button middle | Out-Null
    $a = [double](State)['changes.diff_scroll']
    if ($a -le 0) { throw 'a middle drag expected to scroll the diff' }
    Start-Sleep -Milliseconds 400
    Equal ([double](State)['changes.diff_scroll']) $a 'releasing after a drag ends scrolling'
    Aio mouse wheel "$ax,$ay" 200 --px | Out-Null
    Await-State @{ 'changes.diff_scroll' = '0' } 'back at the top for the long lines' | Out-Null

    # Long lines: notes.txt has a line of 205 bytes on its old side and one of 285 on its new side, both wider
    # than the pane. They scroll sideways, never fade, and stay selectable, in either layout and at any size.
    # The pixel of byte `$col` of flat line `$line` of file `$file`, a pixel past the boundary, allowing for how
    # far the code is scrolled.
    function Point-In($s, $file, $line, $col) {
        $r = Rect $s "changes.line.$file.$line.rect"
        $x = [double]$s["changes.line.$file.$line.text_x"] + ($col * [double]$s['changes.mono_advance']) -
            [double]$s["changes.line.$file.$line.scroll"] + 1
        return "$([int]$x),$([int]($r[1]+$r[3]/2))"
    }
    # Scrolls the code with the wheel and Shift over the new line: rows count down for the right.
    function Scroll-Code($s, $rows) {
        Aio mouse wheel (Middle (Rect $s 'changes.line.2.2.rect')) $rows --px --mods Shift | Out-Null
    }
    # The checks every layout and size owes: nothing fades, the pane cuts the new line, and at the end of the
    # scroll the last byte of each long line is in view, the old and the new line scrolled alike. Starts and
    # leaves the code at its start.
    function Check-Long($label) {
        $s = State
        Equal $s['changes.faded_glyphs'] 0 "${label}: no glyph in the diff fades"
        $limit = [int]$s['changes.h_limit']
        if ($limit -le 0) { throw "$label expected the lines wider than the pane, observed h_limit $limit" }
        Assert-Shown $s 'changes.h_bar_rect'
        $first = [int]$s['changes.line.2.2.visible_to']
        if ($first -ge $newLength) { throw "$label expected the pane to cut the new line, observed $first bytes" }
        Scroll-Code $s -400
        $s = Await-State @{
            'changes.h_scroll' = $limit; 'changes.line.2.2.visible_to' = $newLength
            'changes.line.2.1.visible_to' = $oldLength
        } "$label scrolls to the end of both long lines"
        Equal $s['changes.line.2.1.scroll'] $s['changes.line.2.2.scroll'] "$label`: the old and new line scroll alike"
        Equal $s['changes.faded_glyphs'] 0 "$label`: still no fade at the end"
        Aio capture --out "$data/agent-long-$($label -replace ' ', '-')-end.png" | Out-Null
        Scroll-Code $s 400
        Await-State @{ 'changes.h_scroll' = 0 } "$label returns to the start" | Out-Null
    }
    # Puts notes.txt at the top of the diff, as a change of scale leaves the scroll somewhere else.
    function Show-Notes {
        Open-Files | Out-Null
        Aio type 'notes' | Out-Null
        Await-Like 'changes.file_list.0.label' '*notes.txt*' 'the search keeps notes.txt' | Out-Null
        Aio key Enter | Out-Null
        Await-State @{ 'changes.files_open' = 'false'; 'changes.panel_open' = 'false'; 'changes.top_file' = 2 } `
            'notes.txt is at the top' | Out-Null
    }
    $newLength = $wideNew.Length
    $oldLength = $wideOld.Length
    Open-Files | Out-Null
    Aio type 'notes' | Out-Null
    Await-Like 'changes.file_list.0.label' '*notes.txt*' 'the search keeps notes.txt' | Out-Null
    Aio key Enter | Out-Null
    $s = Await-State @{ 'changes.files_open' = 'false'; 'changes.panel_open' = 'false'; 'changes.top_file' = 2 } `
        'picking notes.txt puts it at the top'
    Equal $s['changes.h_scroll'] 0 'the code starts unscrolled'
    Equal $s['changes.line.2.2.scroll'] 0 'and so does the new line'
    $cut = [int]$s['changes.line.2.2.visible_to']
    Write-Output "PASS the pane shows $cut of the new line's $newLength bytes before scrolling"
    Aio capture --out "$data/agent-long-unified-wide.png" | Out-Null
    Check-Long 'unified wide'
    # The scrollbar is the app's own: thin at rest, wider under the pointer, with a thumb that drags and a track
    # that pages.
    $s = State
    $track = Rect $s 'changes.h_bar_rect'
    $thumb = Rect $s 'changes.h_bar_thumb_rect'
    Aio mouse move (Middle (Rect $s 'changes.line.2.2.rect')) --px | Out-Null
    $rest = (Rect (State) 'changes.h_bar_thumb_rect')[3]
    Aio capture --out "$data/agent-long-scrollbar-rest.png" | Out-Null
    Aio mouse move (Middle $thumb) --px | Out-Null
    $s = Await-State @{ 'changes.hover_part' = 'H_Scroll' } 'the pointer over the scrollbar hovers it'
    $hover = (Rect $s 'changes.h_bar_thumb_rect')[3]
    if ($hover -le $rest) { throw "the scrollbar expected a thicker thumb under the pointer than $rest, observed $hover" }
    Write-Output "PASS the scrollbar thumb widens under the pointer ($rest to $hover px)"
    Aio capture --out "$data/agent-long-scrollbar-hover.png" | Out-Null
    $before = [int]$s['changes.h_scroll']
    Aio mouse click "$([int]($track[0] + $track[2] - 10)),$([int]($track[1] + $track[3] / 2))" --px | Out-Null
    $paged = [int](State)['changes.h_scroll']
    if ($paged -le $before) { throw "a press on the track past the thumb expected to page the code, observed $paged" }
    Write-Output "PASS a press on the track pages the code ($paged columns)"
    Scroll-Code (State) 400
    Await-State @{ 'changes.h_scroll' = 0 } 'back at the start after paging' | Out-Null

    # Shift and the wheel scroll the code sideways, four columns for two rows; the numbers stay where they are.
    $s = State
    $gutter = $s['changes.line.2.2.text_x']
    Scroll-Code $s -2
    $s = Await-State @{ 'changes.h_scroll' = 4 } 'Shift and the wheel scroll the code four columns'
    Equal $s['changes.line.2.2.text_x'] $gutter 'the numbers and the sign stay where they were'
    Equal $s['changes.faded_glyphs'] 0 'a scrolled line does not fade'

    # A drag over the part scrolled into view selects the characters under the pointer, past where the old
    # edge was; a note on it keeps its bytes and its excerpt.
    $limit = [int]$s['changes.h_limit']
    Scroll-Code $s -400
    $s = Await-State @{ 'changes.h_scroll' = $limit } 'scrolled to the end for the drag'
    $from = $newLength - 20
    $to = $newLength - 8
    if ($from -le $cut) { throw "the drag expected to start past the old edge at byte $cut, starts at $from" }
    $want = $wideNew.Substring($from, $to - $from)
    Aio mouse drag (Point-In $s 2 2 $from) (Point-In $s 2 2 $to) --px | Out-Null
    $s = Await-State @{
        'changes.selection_mode' = 'text'; 'changes.selection_text' = $want; 'changes.toolbar_open' = 'true'
    } 'a drag past the old edge selects the characters under the pointer'
    Aio key Alt+2 | Out-Null
    $s = Await-State @{ 'changes.comments' = 1; 'changes.comment.0.partial' = 'true' } `
        'Alt+2 saves a note on part of the scrolled line'
    Equal $s['changes.comment.0.path'] 'notes.txt' 'the note is on notes.txt'
    Equal $s['changes.comment.0.first_byte'] $from 'the note starts at the first selected byte'
    Equal $s['changes.comment.0.last_byte'] $to 'and ends at the last'
    Aio capture --out "$data/agent-long-note.png" | Out-Null
    $s = Await-NoNotices 'no notice covers Copy'
    Aio mouse move (Middle (Rect $s 'changes.copy_rect')) --px | Out-Null
    Click-Rect $s 'changes.copy_rect'
    # The state shows the message's quotes escaped, so the excerpt is matched between them.
    Await-Like 'os.clipboard' "*, at *$want*" 'Copy quotes the excerpt of the scrolled line' | Out-Null
    $s = Await-NoNotices 'no notice covers Discard'
    Aio mouse move (Middle (Rect $s 'changes.discard_rect')) --px | Out-Null
    Click-Rect $s 'changes.discard_rect'
    Await-State @{ 'changes.comments' = 0 } 'Discard clears the long-line note' | Out-Null

    # A drag that runs out of the pane scrolls the code on while the pointer stays out, and selects on.
    $s = State
    Scroll-Code $s 400
    $s = Await-State @{ 'changes.h_scroll' = 0; 'changes.selection_mode' = '' } 'back at the start for the edge drag'
    $row = Rect $s 'changes.line.2.2.rect'
    $edge = "$([int]($row[0] + $row[2] + 4)),$([int]($row[1] + $row[3] / 2))"
    Aio mouse down (Point-In $s 2 2 20) --px | Out-Null
    Aio mouse move $edge --px | Out-Null
    Start-Sleep -Milliseconds 900
    $dragged = [int](State)['changes.h_scroll']
    Aio mouse up $edge --px | Out-Null
    if ($dragged -le 0) { throw "a drag past the edge expected to scroll the code, observed $dragged columns" }
    Write-Output "PASS a drag past the pane's edge scrolled the code $dragged columns"
    $s = Await-State @{ 'changes.selection_mode' = 'text' } 'the drag past the edge selects text'
    $text = $s['changes.selection_text']
    if ($text.Length -le ($cut - 20) -or -not $wideNew.Substring(20).StartsWith($text)) {
        throw "the drag past the edge expected the text from byte 20 on, past byte $cut; observed '$text'"
    }
    Write-Output "PASS the drag past the edge selected $($text.Length) bytes from byte 20, past the old edge"
    Aio key Esc | Out-Null
    $s = Await-State @{ 'changes.selection_mode' = '' } 'Escape ends the selection'

    # The scrollbar along the bottom edge: dragging its thumb scrolls the code.
    Scroll-Code $s 400
    $s = Await-State @{ 'changes.h_scroll' = 0 } 'back at the start for the scrollbar'
    $thumb = Rect $s 'changes.h_bar_thumb_rect'
    $thumbY = [int]($thumb[1] + $thumb[3] / 2)
    Aio mouse drag "$([int]($thumb[0] + $thumb[2] / 2)),$thumbY" "$([int]($thumb[0] + $thumb[2] / 2 + 80)),$thumbY" --px | Out-Null
    $moved = [int](State)['changes.h_scroll']
    if ($moved -le 0) { throw "dragging the scrollbar thumb expected to scroll the code, observed $moved columns" }
    Write-Output "PASS dragging the scrollbar thumb scrolls the code $moved columns"
    Scroll-Code (State) 400
    Await-State @{ 'changes.h_scroll' = 0 } 'back at the start after the scrollbar' | Out-Null

    # At 150% the end of a long line is still reachable and nothing fades.
    Aio dpi 144 | Out-Null
    Start-Sleep -Milliseconds 800
    Show-Notes
    Aio capture --out "$data/agent-long-unified-144.png" | Out-Null
    Check-Long 'unified 150 percent'
    Aio dpi 96 | Out-Null
    Await-State @{ 'changes.row_steps' = '0'; 'changes.h_scroll' = 0 } 'the pane goes back to 100%' | Out-Null
    Show-Notes

    # A narrow pane needs more columns; the same checks hold.
    $wideLimit = [int](State)['changes.h_limit']
    Resize-Window 70
    $s = State
    if ([int]$s['changes.h_limit'] -le $wideLimit) {
        throw "a narrow pane expected more columns than $wideLimit, observed $($s['changes.h_limit'])"
    }
    Write-Output "PASS a narrow pane scrolls further ($($s['changes.h_limit']) columns, $wideLimit when wide)"
    Aio capture --out "$data/agent-long-unified-narrow.png" | Out-Null
    Check-Long 'unified narrow'
    Resize-Window 150

    # Side by side: the old and new line stay on one row and scroll together, each inside its own half.
    $s = State
    Click-Rect $s 'changes.layout_button_rect'
    $s = Await-State @{ 'changes.side_by_side' = 'true'; 'changes.top_file' = 2; 'changes.h_scroll' = 0 } `
        'the layout toggle shows the long lines side by side'
    $old = Rect $s 'changes.line.2.1.rect'
    $new = Rect $s 'changes.line.2.2.rect'
    if (-not ($new[0] -gt $old[0] -and $new[1] -eq $old[1])) {
        throw "side by side expected the old line left of the new on one row, observed $($old -join ',') and $($new -join ',')"
    }
    Write-Output 'PASS the old and new long lines share a row'
    Aio capture --out "$data/agent-long-side-by-side-wide.png" | Out-Null
    Check-Long 'side by side wide'
    $s = State
    Scroll-Code $s -400
    $s = Await-State @{ 'changes.line.2.2.visible_to' = $newLength } 'scrolled to the end in the right half'
    Aio mouse drag (Point-In $s 2 2 $from) (Point-In $s 2 2 $to) --px | Out-Null
    Await-State @{ 'changes.selection_mode' = 'text'; 'changes.selection_text' = $want } `
        'a drag in the right half selects the same characters' | Out-Null
    Aio key Esc | Out-Null
    Await-State @{ 'changes.selection_mode' = '' } 'Escape ends the side by side selection' | Out-Null
    Scroll-Code (State) 400
    Await-State @{ 'changes.h_scroll' = 0 } 'back at the start in side by side' | Out-Null
    Resize-Window 70
    Aio capture --out "$data/agent-long-side-by-side-narrow.png" | Out-Null
    Check-Long 'side by side narrow'
    Resize-Window 150
    $s = State
    Click-Rect $s 'changes.layout_button_rect'
    Await-State @{ 'changes.side_by_side' = 'false'; 'changes.top_file' = 2 } 'the layout toggle goes back to unified' | Out-Null

    # Wrap: the same lines with turns.diff_long_lines = wrap, which the open pane follows at once. Nothing
    # scrolls sideways or fades, every byte is in view, a row is as tall as the lines its text wraps to, and a
    # drag across the wrapped lines selects the bytes under the pointer. The pixel of byte `$col` of flat
    # line `$line` of notes.txt in wrapped lines: its line of text, and the column on it.
    function Point-Wrap($s, $line, $col) {
        $r = Rect $s "changes.line.2.$line.rect"
        $new = Rect $s 'changes.line.2.2.rect'
        $adv = [double]$s['changes.mono_advance']
        $room = $new[0] + $new[2] - [double]$s['changes.line.2.2.text_x']
        $cols = [int][math]::Floor(($room + 0.01) / $adv)
        $one = (Rect $s 'changes.line.2.0.rect')[3]
        $x = [double]$s["changes.line.2.$line.text_x"] + ($col % $cols) * $adv + 1
        $y = $r[1] + ([math]::Floor($col / $cols) + 0.5) * $one
        return "$([int]$x),$([int]$y)"
    }
    function Check-Wrap($label, $sideBySide) {
        $s = State
        Equal $s['changes.long_lines'] 'wrap' "${label}: long lines wrap"
        Equal $s['changes.faded_glyphs'] 0 "${label}: no glyph in the diff fades"
        Equal $s['changes.h_limit'] 0 "${label}: nothing scrolls sideways"
        Assert-Hidden $s 'changes.h_bar_rect'
        $one = Rect $s 'changes.line.2.0.rect'
        $old = Rect $s 'changes.line.2.1.rect'
        $new = Rect $s 'changes.line.2.2.rect'
        if ($new[3] -lt 2 * $one[3]) { throw "$label expected the new line to wrap onto two lines or more, observed height $($new[3]) over $($one[3])" }
        if ($old[3] -lt 2 * $one[3]) { throw "$label expected the old line to take two lines or more, observed height $($old[3])" }
        Write-Output "PASS ${label}: the new line takes $([math]::Round($new[3] / $one[3])) lines"
        Equal $s['changes.line.2.2.visible_to'] $newLength "${label}: every byte of the new line is in view"
        if ($sideBySide) {
            Equal $old[1] $new[1] "${label}: the pair shares a row"
            Equal $old[3] $new[3] "${label}: the pair is as tall as its taller side"
        }
        # A drag from the second line of text to the third selects the bytes between.
        $adv = [double]$s['changes.mono_advance']
        $cols = [int][math]::Floor(($new[0] + $new[2] - [double]$s['changes.line.2.2.text_x'] + 0.01) / $adv)
        $a = $cols + 3
        $b = 2 * $cols + 8
        $text = $wideNew.Substring($a, $b - $a)
        Aio mouse drag (Point-Wrap $s 2 $a) (Point-Wrap $s 2 $b) --px | Out-Null
        Await-State @{ 'changes.selection_mode' = 'text'; 'changes.selection_text' = $text } `
            "${label}: a drag across wrapped lines selects the bytes under the pointer" | Out-Null
        Aio key Esc | Out-Null
        Await-State @{ 'changes.selection_mode' = '' } "${label}: Escape ends the selection" | Out-Null
        Aio capture --out "$data/agent-wrap-$($label -replace ' ', '-').png" | Out-Null
    }
    $wrapIni = Get-Content -LiteralPath "$data/settings.ini" -Raw
    Add-Content -LiteralPath "$data/settings.ini" -Value "`nturns.diff_long_lines = wrap"
    Aio command settings.reload | Out-Null
    Await-State @{ 'changes.long_lines' = 'wrap'; 'changes.top_file' = 2; 'changes.h_limit' = 0 } `
        'the open pane wraps at once and keeps notes.txt at the top' | Out-Null
    Check-Wrap 'unified wide' $false
    # A partial note on a wrapped line keeps its bytes and its excerpt.
    $s = State
    $a = 120
    $b = 131
    $text = $wideNew.Substring($a, $b - $a)
    Aio mouse drag (Point-Wrap $s 2 $a) (Point-Wrap $s 2 $b) --px | Out-Null
    Await-State @{ 'changes.selection_text' = $text; 'changes.toolbar_open' = 'true' } 'a drag on a wrapped line selects its bytes' | Out-Null
    Aio key Alt+2 | Out-Null
    $s = Await-State @{ 'changes.comments' = 1; 'changes.comment.0.partial' = 'true' } 'Alt+2 saves a note on part of the wrapped line'
    Equal $s['changes.comment.0.first_byte'] $a 'the wrapped note starts at the first selected byte'
    Equal $s['changes.comment.0.last_byte'] $b 'and ends at the last'
    Aio capture --out "$data/agent-wrap-note.png" | Out-Null
    $s = Await-NoNotices 'no notice covers Copy on the wrapped line'
    Aio mouse move (Middle (Rect $s 'changes.copy_rect')) --px | Out-Null
    Click-Rect $s 'changes.copy_rect'
    Await-Like 'os.clipboard' "*, at *$text*" 'Copy quotes the excerpt of the wrapped line' | Out-Null
    $s = Await-NoNotices 'no notice covers Discard on the wrapped line'
    Aio mouse move (Middle (Rect $s 'changes.discard_rect')) --px | Out-Null
    Click-Rect $s 'changes.discard_rect'
    Await-State @{ 'changes.comments' = 0 } 'Discard clears the wrapped note' | Out-Null
    # Narrower, the rows wrap further and the top row stays where it was.
    $wideHeight = (Rect (State) 'changes.line.2.2.rect')[3]
    Resize-Window 70
    $s = Await-State @{ 'changes.top_file' = 2 } 'a narrow pane keeps notes.txt at the top'
    if ((Rect $s 'changes.line.2.2.rect')[3] -le $wideHeight) { throw "a narrow pane expected the new line taller than $wideHeight" }
    Write-Output 'PASS a narrow pane wraps the new line onto more lines'
    Check-Wrap 'unified narrow' $false
    Resize-Window 150
    $s = State
    Click-Rect $s 'changes.layout_button_rect'
    Await-State @{ 'changes.side_by_side' = 'true'; 'changes.top_file' = 2 } 'wrapped, the layout toggle shows side by side' | Out-Null
    Check-Wrap 'side by side wide' $true
    Resize-Window 70
    Await-State @{ 'changes.top_file' = 2 } 'the narrow side by side pane keeps notes.txt at the top' | Out-Null
    Check-Wrap 'side by side narrow' $true
    Resize-Window 150
    $s = State
    Click-Rect $s 'changes.layout_button_rect'
    Await-State @{ 'changes.side_by_side' = 'false'; 'changes.top_file' = 2 } 'wrapped, the layout toggle goes back to unified' | Out-Null
    Set-Content -LiteralPath "$data/settings.ini" -Value $wrapIni -NoNewline
    Aio command settings.reload | Out-Null
    Await-State @{ 'changes.long_lines' = 'scroll'; 'changes.top_file' = 2 } 'the setting back to scroll puts the sideways scroll back' | Out-Null

    # Back to live.py at the top, unscrolled, for the notes below.
    Open-Files | Out-Null
    Aio type 'live' | Out-Null
    Await-Like 'changes.file_list.0.label' '*live.py*' 'the search keeps live.py' | Out-Null
    Aio key Enter | Out-Null
    Await-State @{ 'changes.files_open' = 'false'; 'changes.panel_open' = 'false'; 'changes.top_file' = 0 } `
        'picking live.py scrolls to the top again' | Out-Null

    # Notes: drag over text and label it with Alt+2, pick lines with Alt and delete them with Del, type to write
    # a comment with a suggestion from the tool and save it with Ctrl+Enter, edit one note, remove one, copy
    # the message, then send it to the reviewer's pane.
    Await-File $reviewReady 'the reviewer accepts pasted text' | Out-Null
    # The theme step's settings reload left a notice over the send bar's Copy button.
    $s = Await-NoNotices 'no notice covers the send bar'
    # The pixel of byte `$col` of flat line `$line` of file 0, a pixel past the boundary, and the row's middle.
    function Point($s, $line, $col) {
        $r = Rect $s "changes.line.0.$line.rect"
        $x = [double]$s["changes.line.0.$line.text_x"] + $col * [double]$s['changes.mono_advance'] + 1
        return "$([int]$x),$([int]($r[1]+$r[3]/2))"
    }
    # Text: "greet" of `def greet(name):`, then Alt+2 applies the second quick label.
    Aio mouse drag (Point $s 1 4) (Point $s 1 9) --px | Out-Null
    $s = Await-State @{ 'changes.selection_mode' = 'text'; 'changes.toolbar_open' = 'true' } 'a drag over text selects it'
    Equal $s['changes.selection_text'] 'greet' 'the selected text'
    # The toolbar sits just above the first selected line: its bottom edge is 6 DIP over the line's top.
    $bar = Rect $s 'changes.toolbar_rect'
    $line = Rect $s 'changes.line.0.1.rect'
    $gap = $line[1] - ($bar[1] + $bar[3])
    $want = 6 * [double]$s['window.scale']
    if ([math]::Abs($gap - $want) -gt 1.5) { throw "the toolbar sits $gap px over the line, expected $want" }
    Write-Output 'PASS the toolbar sits 6 DIP above the first selected line'
    Aio capture --out "$data/agent-toolbar.png" | Out-Null
    Aio key Alt+2 | Out-Null
    $s = Await-State @{ 'changes.comments' = 1; 'changes.toolbar_open' = 'false' } 'Alt+2 adds the second label'
    Equal $s['changes.comment.0.kind'] 'Label' 'the note is a label'
    Equal $s['changes.comment.0.partial'] 'true' 'on part of its line'
    # Lines: Alt picks whole lines, and Del asks for their deletion.
    Aio mouse drag (Point $s 3 0) (Point $s 3 4) --px --mods Alt | Out-Null
    $s = Await-State @{ 'changes.selection_mode' = 'lines'; 'changes.toolbar_open' = 'true' } 'Alt picks whole lines'
    Aio key Delete | Out-Null
    $s = Await-State @{ 'changes.comments' = 2 } 'Delete adds a deletion'
    Equal $s['changes.comment.1.kind'] 'Delete' 'the note is a deletion'
    Equal $s['changes.comment.1.partial'] 'false' 'of whole lines'
    # A comment: select "hello", type a letter to start it, add a suggestion with the tool, save with Ctrl+Enter.
    $comment = 'please rename greet to welcome'
    Aio mouse drag (Point $s 2 12) (Point $s 2 17) --px | Out-Null
    $s = Await-State @{ 'changes.selection_text' = 'hello'; 'changes.toolbar_open' = 'true' } 'a drag selects "hello"'
    Aio key p | Out-Null
    $s = Await-State @{ 'changes.editing' = 2 } 'a typed letter starts a comment'
    Aio type 'lease rename greet to welcome' | Out-Null
    $s = Await-State @{ 'changes.editor_text' = $comment } 'the text goes into the editor'
    Click-Rect $s 'changes.editor.suggest_rect'
    $s = Await-Like 'changes.editor_text' '*suggestion*return*hello*name*' 'Suggest change inserts the selected lines'
    Aio capture --out "$data/agent-editor.png" | Out-Null
    Aio key Ctrl+Enter | Out-Null
    $s = Await-State @{ 'changes.comments' = 3; 'changes.editing' = -1; 'changes.comment.2.kind' = 'Comment' } 'Ctrl+Enter saves the comment'
    Like $s['changes.comment.2.text'] "$comment*suggestion*" 'with its suggestion'
    Aio capture --out "$data/agent-notes.png" | Out-Null
    # Edit the comment, then remove the deletion.
    Click-Rect $s 'changes.comment.2.edit_rect'
    Await-State @{ 'changes.editing' = 2 } 'Edit opens the note' | Out-Null
    Aio key Ctrl+End | Out-Null
    Aio key Enter | Out-Null
    Aio type 'Thanks.' | Out-Null
    Aio key Ctrl+Enter | Out-Null
    $s = Await-State @{ 'changes.comments' = 3; 'changes.editing' = -1 } 'Ctrl+Enter saves the edit'
    Like $s['changes.comment.2.text'] '*Thanks.' 'the edited text is saved'
    Click-Rect $s 'changes.comment.1.remove_rect'
    $s = Await-State @{ 'changes.comments' = 2 } 'Remove takes the deletion away' | Out-Null
    $s = State
    Click-Rect $s 'changes.copy_rect'
    $s = Await-Like 'os.clipboard' '*live.py, line 2, at*greet*Verify this*' 'Copy puts the notes on the clipboard'
    Like $s['os.clipboard'] '*Suggested replacement for line 3*' 'the message carries the suggestion'
    Like $s['os.clipboard'] '*Thanks.*' 'and the edited comment'
    Equal $s['changes.comments'] 2 'Copy keeps the notes'
    $s = Await-State @{ 'changes.send.can_send' = 'true' } 'Send is offered while the reviewer takes pasted text'
    Click-Rect $s 'changes.send_rect'
    Await-State @{ 'changes.comments' = 0 } 'Send clears the notes' | Out-Null
    Focus-Pane $reviewPane
    Aio wait text 'ECHO:Review comments on your changes:' | Out-Null
    Write-Output "PASS the notes reach the reviewer's prompt"

    # The default view and filter settings: a pane opened from an agent pane takes them.
    $ini = Get-Content -LiteralPath "$data/settings.ini" -Raw
    Add-Content -LiteralPath "$data/settings.ini" -Value "`nturns.diff_view = side_by_side`nturns.diff_filter = !long"
    Aio command settings.reload | Out-Null
    Aio command pane.agent_changes | Out-Null
    Await-State @{
        'changes.active' = 'true'; 'changes.scope' = 'agent'; 'changes.side_by_side' = 'true'
        'changes.filter' = '!long'; 'changes.hidden_files' = 1; 'changes.files' = 3
        'changes.file.0.path' = 'live.py'; 'changes.file.1.path' = 'notes.txt'; 'changes.file.2.path' = 'zz.md'
        'changes.settled' = 'true'
    } 'a new pane opens side by side and filtered when the settings say so' | Out-Null
    Close-Changes 2
    Set-Content -LiteralPath "$data/settings.ini" -Value $ini -NoNewline
    Aio command settings.reload | Out-Null
    Focus-Pane $reviewPane

    # Back at its shell the reviewer takes no comments: Send is refused with a reason, and Discard clears.
    Aio run 'EXIT' | Out-Null
    Aio wait text 'REVIEWER_DONE' | Out-Null
    Focus-Pane $reviewChanges
    $s = State
    Aio mouse drag (Point $s 0 0) (Point $s 3 0) --px --mods Alt | Out-Null
    Await-State @{ 'changes.selection' = '0:0-3'; 'changes.selection_mode' = 'lines' } 'Alt picks the first to the last line' | Out-Null
    Aio key Enter | Out-Null
    Await-State @{ 'changes.editing' = 0 } 'Enter with the toolbar shown opens the editor' | Out-Null
    Aio type 'Second look' | Out-Null
    Aio key Ctrl+Enter | Out-Null
    Await-State @{ 'changes.comments' = 1; 'changes.editing' = -1 } 'a second comment is saved' | Out-Null
    # The bracketed paste mode goes off as the reviewer exits, before the process poll sees it gone, so the
    # reason is awaited too.
    $s = Await-State @{
        'changes.send.can_send' = 'false'; 'changes.send.reason' = "The agent isn't running in its pane."
    } 'Send is refused once the reviewer exits to its shell' 20
    # Copy and Send leave notices over the send bar too.
    $s = Await-NoNotices 'no notice covers Discard'
    Aio mouse move (Middle (Rect $s 'changes.discard_rect')) --px | Out-Null
    Click-Rect $s 'changes.discard_rect'
    Await-State @{ 'changes.comments' = 0 } 'Discard clears the comments' | Out-Null

    # (e) An agent with twelve quick turns: the strip shows the newest ten and marks the two older ones.
    # After each turn the agent waits for the journey's go flag, written once that turn is saved, so every
    # turn ends before the next begins and a lost turn shows at the turn that lost it.
    $strip = "$data/strip.ps1"
    Set-Content -LiteralPath $strip -Value (@("`$work = '$work'", "`$data = '$data'") + $report + @(
        '$Host.UI.RawUI.WindowTitle = ''Strip agent'''
        'for ($i = 1; $i -le 12; $i++) {'
        '    Report ''working'' '''''
        '    Start-Sleep -Milliseconds 400'
        '    Set-Content -LiteralPath (Join-Path $work (''strip-'' + $i + ''.txt'')) -Value "turn $i"'
        '    Start-Sleep -Milliseconds 700'
        '    Report ''done'' (''Strip '' + $i)'
        '    $go = Join-Path $data (''strip-go-'' + $i + ''.flag'')'
        '    while (-not (Test-Path -LiteralPath $go)) { Start-Sleep -Milliseconds 50 }'
        '}'
        'Start-Sleep -Seconds 900'
    ))
    # The recorder's and the focused pane's turn keys, for a failure in this section.
    function Turn-Dump {
        $s = State
        $keys = @($s.Keys | Where-Object { $_ -like 'turns.*' -or $_ -like 'changes.turn.*' -or $_ -like 'changes.strip*' } |
            Sort-Object)
        return ($keys | ForEach-Object { "$_=$($s[$_])" }) -join '; '
    }
    try {
        Aio command tab.new | Out-Null
        Await-State @{ 'tabs.count' = 5; 'tabs.selected' = 5 } 'tab 5 opens' | Out-Null
        Aio wait text 'PS ' | Out-Null
        $stripPane = (State)['panes.focused']
        Aio run "cd '$work'; Write-Output ('READY_' + 'strip')" | Out-Null
        Aio wait text 'READY_strip' | Out-Null
        $saved = [int](State)['turns.saved']
        Aio run "pwsh -NoProfile -File '$strip'" | Out-Null
        for ($i = 1; $i -le 12; $i++) {
            Await-AtLeast 'turns.saved' ($saved + $i) "strip turn $i is saved" 10 | Out-Null
            Set-Content -LiteralPath "$data/strip-go-$i.flag" -Value 'x'
        }
        Write-Output 'PASS the strip agent saved its twelve turns'
        $s = Open-Changes $stripPane 'the strip agent opens the agent scope'
        $s = Await-State @{
            'changes.turns' = 12; 'changes.first' = 0; 'changes.last' = 0; 'changes.settled' = 'true'
            'changes.strip_bars' = 10; 'changes.strip_older' = 2; 'changes.strip_newer' = 0
        } 'the strip shows ten bars and marks two older turns'
        $s = Open-Panel
        Aio capture --out "$data/agent-strip-cap.png" | Out-Null
        Click-Rect $s 'changes.strip_older_rect'
        Await-AtLeast 'changes.strip_newer' 1 'the older marker shows older bars and marks newer ones' | Out-Null
    } catch {
        throw "$($_.Exception.Message)`nturn state: $(Turn-Dump)"
    }

    # Tooltips name each control and, where it has one, its key.
    $s = State
    Aio mouse move (Middle (Rect $s 'changes.step_back_rect')) --px | Out-Null
    $s = Await-State @{ 'changes.tooltip' = 'Older turn' } 'the back step has its tooltip'
    Like $s['changes.tooltip_key'] '*Left*' 'the back step tooltip names its key'
    Aio mouse move (Middle (Rect $s 'changes.range_label_rect')) --px | Out-Null
    $s = Await-State @{ 'changes.tooltip' = 'Choose turns' } 'the range label has its tooltip'
    # The row's buttons sit outside the panel, so the panel closes first.
    Close-Panel | Out-Null
    $s = State
    Aio mouse move (Middle (Rect $s 'changes.filter_button_rect')) --px | Out-Null
    Await-State @{ 'changes.tooltip' = 'Filter files' } 'the filter button has its tooltip' | Out-Null
    Aio mouse move (Middle (Rect $s 'changes.files_button_rect')) --px | Out-Null
    $s = Await-State @{ 'changes.tooltip' = 'Files in this diff' } 'the files button has its tooltip'
    Aio mouse move (Middle (Rect $s 'changes.summary_rect')) --px | Out-Null
    $s = Await-State @{ 'changes.tooltip' = 'Source and turns' } 'the summary has its tooltip'
    Like $s['changes.tooltip_key'] '*K*' 'the summary tooltip names Ctrl+K'
    Aio mouse move (Middle (Rect $s 'changes.overview_rect')) --px | Out-Null
    Await-State @{ 'changes.tooltip' = 'Overview: click or drag to scroll' } 'the overview strip has its tooltip' | Out-Null

    # (f) An agent whose turns change no file: only a turn that holds a changed file is listed. The agent
    # writes a file in its first turn, then answers without an edit, then creates and deletes a file (a net
    # nothing), then writes a file again. Each turn waits for the journey's go flag so every state is read.
    $quiet = "$data/quiet.ps1"
    function Quiet-Go($n) { Set-Content -LiteralPath "$data/quiet-go-$n.flag" -Value 'x' }
    Set-Content -LiteralPath $quiet -Value (@("`$work = '$work'", "`$data = '$data'") + $report + @(
        '$Host.UI.RawUI.WindowTitle = ''Quiet agent'''
        'function Step($n) {'
        '    $go = Join-Path $data (''quiet-go-'' + $n + ''.flag'')'
        '    while (-not (Test-Path -LiteralPath $go)) { Start-Sleep -Milliseconds 50 }'
        '}'
        'Report ''working'' '''''
        'Start-Sleep -Milliseconds 400'
        'Set-Content -LiteralPath (Join-Path $work ''quiet-1.txt'') -Value ''one'''
        'Start-Sleep -Milliseconds 700'
        'Report ''done'' ''Quiet 1'''
        'Step 1'
        'Report ''working'' '''''
        'Step 2'
        'Report ''done'' ''Quiet 2'''
        'Step 3'
        'Report ''working'' '''''
        'Start-Sleep -Milliseconds 400'
        'Set-Content -LiteralPath (Join-Path $work ''quiet-tmp.txt'') -Value ''tmp'''
        'Step 4'
        'Remove-Item -LiteralPath (Join-Path $work ''quiet-tmp.txt'')'
        'Start-Sleep -Milliseconds 700'
        'Report ''done'' ''Quiet 3'''
        'Step 5'
        'Report ''working'' '''''
        'Start-Sleep -Milliseconds 400'
        'Set-Content -LiteralPath (Join-Path $work ''quiet-2.txt'') -Value ''two'''
        'Start-Sleep -Milliseconds 700'
        'Report ''done'' ''Quiet 4'''
        'Start-Sleep -Seconds 900'
    ))
    Aio command tab.new | Out-Null
    Await-State @{ 'tabs.count' = 6; 'tabs.selected' = 6 } 'tab 6 opens' | Out-Null
    Aio wait text 'PS ' | Out-Null
    $quietPane = (State)['panes.focused']
    Aio run "cd '$work'; Write-Output ('READY_' + 'quiet')" | Out-Null
    Aio wait text 'READY_quiet' | Out-Null
    $saved = [int](State)['turns.saved']
    Aio run "pwsh -NoProfile -File '$quiet'" | Out-Null
    Await-AtLeast 'turns.saved' ($saved + 1) 'the quiet agent saves its first turn' 15 | Out-Null
    Await-State @{ 'turns.open' = 0 } 'the first turn has ended' | Out-Null
    $s = Open-Changes $quietPane 'the quiet agent opens the agent scope'
    $s = Await-State @{
        'changes.turns' = 1; 'changes.first' = 0; 'changes.last' = 0; 'changes.files' = 1; 'changes.settled' = 'true'
        'changes.strip_bars' = 1; 'changes.range_label' = 'Turn 1'
    } 'one turn with a file is listed'
    # An open turn with no file yet is not a bar.
    Quiet-Go 1
    Await-State @{ 'turns.open' = 1 } 'the second turn is open with no file written' | Out-Null
    Start-Sleep -Milliseconds 1500
    $s = Await-State @{
        'changes.turns' = 1; 'changes.settled' = 'true'; 'changes.strip_bars' = 1; 'changes.range_label' = 'Turn 1'
        'changes.turn.0.live' = 'false'; 'changes.files' = 1
    } 'an open turn that has written no file is not listed'
    $s = Open-Panel
    Aio capture --out "$data/agent-empty-open.png" | Out-Null
    Close-Panel | Out-Null
    # Ended without an edit, it is not saved and is not listed.
    Quiet-Go 2
    Await-State @{ 'turns.open' = 0 } 'the second turn ended' | Out-Null
    Start-Sleep -Milliseconds 1000
    Equal (State)['turns.saved'] ($saved + 1) 'a turn with no file is not saved'
    Await-State @{ 'changes.turns' = 1; 'changes.settled' = 'true'; 'changes.strip_bars' = 1 } 'the ended empty turn is not listed' | Out-Null
    # A turn lists once it holds a file, and drops out when its edits net to nothing.
    Quiet-Go 3
    $s = Await-State @{ 'changes.turns' = 2; 'changes.turn.0.live' = 'true'; 'changes.settled' = 'true' } `
        'a turn is listed once it has written a file'
    Quiet-Go 4
    Await-State @{ 'turns.open' = 0 } 'the third turn ended' | Out-Null
    Start-Sleep -Milliseconds 1000
    Equal (State)['turns.saved'] ($saved + 1) 'a turn whose edits net to nothing is not saved'
    Await-State @{ 'changes.turns' = 1; 'changes.settled' = 'true'; 'changes.strip_bars' = 1 } 'the turn that netted to nothing is not listed' | Out-Null
    # The next turn with a file is turn 2: hidden turns are not counted.
    Quiet-Go 5
    Await-AtLeast 'turns.saved' ($saved + 2) 'the fourth turn is saved' 15 | Out-Null
    $s = Await-State @{
        'changes.turns' = 2; 'changes.first' = 0; 'changes.last' = 0; 'changes.files' = 1; 'changes.settled' = 'true'
        'changes.strip_bars' = 2; 'changes.range_label' = 'Turn 2'; 'changes.file.0.path' = 'quiet-2.txt'
    } 'two listed turns number 1 and 2 across the hidden ones'
    Equal $s['changes.turn.0.live'] 'false' 'the newest listed turn has ended'
    $s = Open-Panel
    Aio capture --out "$data/agent-empty-turns.png" | Out-Null
    Close-Panel | Out-Null

    # Recording off asks to delete what was recorded.
    if ((Turn-Directories).Count -eq 0) { throw "no agent-turns directory under $data while recording" }
    Write-Output 'PASS the recorded turns exist on disk'
    $ini = Get-Content -LiteralPath "$data/settings.ini" -Raw
    Set-Content -LiteralPath "$data/settings.ini" -Value ($ini -replace '(?m)^turns\.record\s*=\s*true', 'turns.record = false') -NoNewline
    Aio command settings.reload | Out-Null
    Await-State @{ 'turns.delete_open' = 'true' } 'turning recording off asks' | Out-Null
    Aio capture --out "$data/delete-turns.png" | Out-Null
    # The question opens with focus on Keep; Left moves it to Delete.
    Aio key Left Enter | Out-Null
    Await-State @{ 'turns.delete_open' = 'false'; 'turns.recording' = 'false' } `
        'accepting closes the question and recording is off' | Out-Null
    $deadline = (Get-Date).AddSeconds(15)
    while ((Turn-Directories).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if ((Turn-Directories).Count -gt 0) {
        throw "Delete left $((Turn-Directories | ForEach-Object FullName) -join ', ')"
    }
    Write-Output 'PASS Delete removes every recorded copy'
} finally {
    & $ctl --name $name stop | Out-Null
    foreach ($path in @($wtA, $wtB)) { Remove-Worktree $path }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
