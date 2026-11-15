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
# Picks choice `$index` of the focused pane's source dropdown: the agents, All agents, then Uncommitted,
# Staged and Unstaged changes. The list stops at its ends, so enough Up presses reach the first choice
# wherever it opened.
function Choose-Source($index, $label) {
    $s = State
    Click-Rect $s 'changes.scope_rect'
    Await-State @{ 'changes.dropdown_open' = 'true' } "the source dropdown opens ($label)" | Out-Null
    $keys = @(@('Up') * ([int]$s['changes.agents'] + 4)) + @(@('Down') * $index) + @('Enter')
    Aio key @keys | Out-Null
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
# Only the reviewer of section (d) edits it, for a modified file whose two sides show side by side.
Set-Content -LiteralPath (Join-Path $work 'notes.txt') -Value @('alpha', 'beta', 'gamma', 'delta')
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

    # The toolbar strip has one bar per turn, oldest at the left; turns are numbered oldest = 1.
    $newest = Rect $s 'changes.strip.0.rect'
    $older = Rect $s 'changes.strip.1.rect'
    if (-not ($newest[2] -gt 0 -and $older[2] -gt 0 -and $newest[0] -gt $older[0])) {
        throw "strip bars expected the newest right of the older, observed $($newest -join ',') and $($older -join ',')"
    }
    Write-Output 'PASS the strip shows the newest turn right of the older one'
    Equal $s['changes.range_label'] 'Turn 2' 'the range label numbers the newest turn'
    Aio key Left | Out-Null
    $s = Await-State @{
        'changes.first' = 1; 'changes.last' = 1; 'changes.files' = 2; 'changes.range_label' = 'Turn 1'
        'changes.settled' = 'true'; 'changes.file.0.path' = 'a.txt'; 'changes.file.1.path' = 'c.txt'
    } 'Left steps to the older turn'
    Equal $s['changes.file.0.path'] 'a.txt' 'the first turn lists a.txt'
    Equal $s['changes.file.1.path'] 'c.txt' 'the first turn lists the new c.txt'
    Click-Rect $s 'changes.step_forward_rect'
    $s = Await-State @{
        'changes.first' = 0; 'changes.last' = 0; 'changes.range_label' = 'Turn 2'; 'changes.settled' = 'true'
        'changes.file.1.path' = 'b.txt'
    } 'the forward step selects the newer turn'
    Click-Rect $s 'changes.step_back_rect'
    $s = Await-State @{ 'changes.first' = 1; 'changes.last' = 1; 'changes.settled' = 'true'; 'changes.file.1.path' = 'c.txt' } `
        'the back step selects the older turn'
    Aio key Shift+Right | Out-Null
    $s = Await-State @{ 'changes.first' = 0; 'changes.last' = 1; 'changes.files' = 3; 'changes.settled' = 'true' } `
        'Shift+Right extends the selection over both turns'
    # The en dash arrives escaped, so only the ends of the label are compared.
    Like $s['changes.range_label'] 'Turns 1*2' 'the range label names the selected run'
    # The range label opens the turn list; Escape closes it.
    Click-Rect $s 'changes.range_label_rect'
    Await-State @{ 'changes.turn_list_open' = 'true' } 'the range label opens the turn list' | Out-Null
    Aio key Esc | Out-Null
    $s = Await-State @{
        'changes.turn_list_open' = 'false'; 'changes.first' = 0; 'changes.last' = 1; 'changes.settled' = 'true'
    } 'Escape closes the turn list and keeps the selection'
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
    # The picker lists Follow the agent, the followed worktree, then the folder's own.
    Click-Rect $s 'changes.worktree_rect'
    Await-State @{ 'changes.dropdown_open' = 'true' } 'the worktree picker opens' | Out-Null
    Aio key Down Down Enter | Out-Null
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
        if ($node -eq $panes[0]) { Aio capture --out "$data/agent-shared-worktrees.png" | Out-Null }
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
        'Set-Content -LiteralPath (Join-Path $work ''notes.txt'') -Value @(''alpha'', ''BETA'', ''gamma'', ''delta'')'
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
    $s = Await-State @{
        'changes.turns' = 1; 'changes.turn.0.live' = 'true'; 'changes.first' = 0; 'changes.last' = 0
        'changes.settled' = 'true'
    } 'the open turn is a live row, selected'
    $reviewChanges = $s['panes.focused']
    Like $s['changes.agent'] '*Reviewer agent*' 'the source field names the reviewer'
    Await-Like 'changes.range_label' 'Working*' 'the range label says the live turn is working' | Out-Null
    Set-Content -LiteralPath $reviewGo -Value 'x'
    # Paths sort, so live.py comes first, then long.txt, notes.txt and zz.md.
    $s = Await-State @{
        'changes.turn.0.live' = 'true'; 'changes.files' = 4; 'changes.file.0.path' = 'live.py'
        'changes.file.1.path' = 'long.txt'; 'changes.file.2.path' = 'notes.txt'; 'changes.file.3.path' = 'zz.md'
        'changes.settled' = 'true'
    } 'the live turn lists the files the agent wrote within 3 s' 3
    Set-Content -LiteralPath $reviewEnd -Value 'x'
    Await-AtLeast 'turns.saved' ($saved + 1) 'the live turn is saved at its end' | Out-Null
    $s = Await-State @{
        'changes.turns' = 1; 'changes.turn.0.live' = 'false'; 'changes.first' = 0; 'changes.last' = 0
        'changes.files' = 4; 'changes.file.0.path' = 'live.py'; 'changes.file.0.highlighted' = 'true'
        'changes.settled' = 'true'
    } 'the saved turn keeps its selection and highlights live.py'
    Equal $s['changes.file.0.added'] 4 'live.py adds its four lines'
    Aio capture --out "$data/agent-live-highlight.png" | Out-Null

    # The file list: typing part of a later file's path and Enter puts that file's header at the top.
    Click-Rect $s 'changes.files_button_rect'
    Await-State @{ 'changes.files_open' = 'true' } 'the files button opens the file list' | Out-Null
    Aio type 'long' | Out-Null
    Await-Like 'changes.file_list.0.label' '*long.txt*' 'the search keeps long.txt' | Out-Null
    Aio key Enter | Out-Null
    $s = Await-State @{ 'changes.files_open' = 'false'; 'changes.top_file' = 1 } `
        'picking long.txt scrolls its header to the top'
    # Side by side keeps the top file in view; a modified file shows its old line left of its new one.
    Click-Rect $s 'changes.layout_button_rect'
    $s = Await-State @{ 'changes.side_by_side' = 'true'; 'changes.top_file' = 1 } `
        'the layout toggle shows the diff side by side'
    Click-Rect $s 'changes.files_button_rect'
    Await-State @{ 'changes.files_open' = 'true' } 'the file list opens again' | Out-Null
    Aio type 'notes' | Out-Null
    Await-Like 'changes.file_list.0.label' '*notes.txt*' 'the search keeps notes.txt' | Out-Null
    Aio key Enter | Out-Null
    $s = Await-State @{ 'changes.files_open' = 'false'; 'changes.side_by_side' = 'true' } 'picking notes.txt closes the list'
    Aio capture --out "$data/agent-side-by-side.png" | Out-Null
    # notes.txt: alpha, -beta, +BETA, gamma, delta; the removed and the added line share a row.
    $old = Rect $s 'changes.line.2.1.rect'
    $new = Rect $s 'changes.line.2.2.rect'
    if (-not ($old[2] -gt 0 -and $new[2] -gt 0 -and $new[0] -gt $old[0] -and $new[1] -eq $old[1])) {
        throw "side by side expected beta left of BETA on one row, observed $($old -join ',') and $($new -join ',')"
    }
    Write-Output 'PASS the removed and added lines share a row, old on the left'
    Click-Rect $s 'changes.line.2.2.rect'
    Await-State @{ 'changes.selection' = '2:2-2' } 'a click on a right-half line selects the new line' | Out-Null
    # Back to unified, with live.py at the top again for the comments below.
    $s = State
    Click-Rect $s 'changes.files_button_rect'
    Await-State @{ 'changes.files_open' = 'true' } 'the file list opens a third time' | Out-Null
    Aio type 'live' | Out-Null
    Await-Like 'changes.file_list.0.label' '*live.py*' 'the search keeps live.py' | Out-Null
    Aio key Enter | Out-Null
    $s = Await-State @{ 'changes.files_open' = 'false'; 'changes.top_file' = 0 } 'picking live.py scrolls to the top'
    Click-Rect $s 'changes.layout_button_rect'
    $s = Await-State @{ 'changes.side_by_side' = 'false'; 'changes.top_file' = 0 } 'the layout toggle goes back to unified'

    # The file list's search takes a regular expression with its .* toggle; an invalid one matches nothing.
    Click-Rect $s 'changes.files_button_rect'
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
    Await-State @{ 'changes.files_open' = 'false' } 'Esc closes the file list' | Out-Null

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
    Click-Rect $s 'changes.files_button_rect'
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
    Click-Rect $s 'changes.files_button_rect'
    Await-State @{ 'changes.files_open' = 'true' } 'the file list opens for long.txt' | Out-Null
    Aio type 'long' | Out-Null
    Await-Like 'changes.file_list.0.label' '*long.txt*' 'the search finds long.txt' | Out-Null
    Aio key Enter | Out-Null
    $s = Await-State @{ 'changes.files_open' = 'false'; 'changes.top_file' = 1 } 'picking long.txt puts it at the top'
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
    Click-Rect $s 'changes.files_button_rect'
    Await-State @{ 'changes.files_open' = 'true' } 'the file list opens for live.py' | Out-Null
    Aio type 'live' | Out-Null
    Await-Like 'changes.file_list.0.label' '*live.py*' 'the search finds live.py again' | Out-Null
    Aio key Enter | Out-Null
    $s = Await-State @{ 'changes.files_open' = 'false'; 'changes.top_file' = 0 } 'picking live.py scrolls back to the top'

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

    # Comments: select two lines, write a comment, copy it, then send it to the reviewer's pane.
    Await-File $reviewReady 'the reviewer accepts pasted text' | Out-Null
    $comment = 'Please rename greet to welcome'
    Click-Rect $s 'changes.line.0.1.rect'
    $s = Await-State @{ 'changes.selection' = '0:1-1' } 'a click on a diff line selects it'
    Click-Rect $s 'changes.line.0.2.rect' --mods Shift
    $s = Await-State @{ 'changes.selection' = '0:1-2' } 'Shift+click extends the selection to the next line'
    Click-Rect $s 'changes.comment_button_rect'
    Await-State @{ 'changes.editing' = 0; 'changes.comments' = 0 } 'the Comment button opens the editor' | Out-Null
    Aio type $comment | Out-Null
    Aio key Enter | Out-Null
    $s = Await-State @{
        'changes.comments' = 1; 'changes.editing' = -1; 'changes.comment.0.path' = 'live.py'
        'changes.comment.0.first' = 2; 'changes.comment.0.last' = 3; 'changes.comment.0.text' = $comment
        'changes.comment.0.detached' = 'false'
    } 'Enter saves the comment on lines 2-3'
    Aio capture --out "$data/agent-comment.png" | Out-Null
    Click-Rect $s 'changes.copy_rect'
    $s = Await-Like 'os.clipboard' "*live.py, lines 2-3*$comment*" 'Copy puts the comments on the clipboard'
    Equal $s['changes.comments'] 1 'Copy keeps the comments'
    $s = Await-State @{ 'changes.send.can_send' = 'true' } 'Send is offered while the reviewer takes pasted text'
    Click-Rect $s 'changes.send_rect'
    Await-State @{ 'changes.comments' = 0 } 'Send clears the comments' | Out-Null
    Focus-Pane $reviewPane
    Aio wait text "ECHO:$comment" | Out-Null
    Write-Output "PASS the comment reaches the reviewer's prompt"

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
    Click-Rect $s 'changes.line.0.0.rect'
    $s = Await-State @{ 'changes.selection' = '0:0-0' } 'a click selects the first line again'
    Click-Rect $s 'changes.line.0.3.rect' --mods Shift
    Await-State @{ 'changes.selection' = '0:0-3' } 'Shift+click extends the selection to the last line' | Out-Null
    Aio key Enter | Out-Null
    Await-State @{ 'changes.editing' = 0 } 'Enter with a selection opens the editor' | Out-Null
    Aio type 'Second look' | Out-Null
    Aio key Enter | Out-Null
    Await-State @{ 'changes.comments' = 1; 'changes.editing' = -1 } 'a second comment is saved' | Out-Null
    # The bracketed paste mode goes off as the reviewer exits, before the process poll sees it gone, so the
    # reason is awaited too.
    $s = Await-State @{
        'changes.send.can_send' = 'false'; 'changes.send.reason' = "The agent isn't running in its pane."
    } 'Send is refused once the reviewer exits to its shell' 20
    Click-Rect $s 'changes.discard_rect'
    Await-State @{ 'changes.comments' = 0 } 'Discard clears the comments' | Out-Null

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
