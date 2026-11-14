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
function Equal($actual, $expected, $label) {
    if ("$actual" -ne "$expected") { throw "$label expected $expected, observed $actual" }
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
            throw "$label timed out: $seen"
        }
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

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null
Git init -q
Set-Content -LiteralPath (Join-Path $work 'a.txt') -Value @('one', 'two', 'three')
Set-Content -LiteralPath (Join-Path $work 'b.txt') -Value @('keep', 'drop')
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

    # The agent reports through OSC 7501 with no id, which is the pane's main record. Between its two
    # turns it waits for the flag the journey creates after it has edited a.txt from outside.
    $go = "$data/go.flag"
    $finished = "$data/finished.flag"
    $agent = "$data/agent.ps1"
    Set-Content -LiteralPath $agent -Value @(
        "`$work = '$work'"
        "`$go = '$go'"
        "`$finished = '$finished'"
        'function Report($state, $message) {'
        '    $text = "]7501;state=$state" + ":app=claude"'
        '    if ($message) { $text += ":msg=" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($message)) }'
        '    [Console]::Write([char]27 + $text + [char]7)'
        '}'
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
        'Start-Sleep -Seconds 900'
    )
    Aio run "cd '$work'" | Out-Null
    Aio wait text 'agent-changes-repo' | Out-Null
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
        'changes.count' = 1; 'changes.scope' = 'agent'; 'changes.turns' = 2
        'changes.first' = 0; 'changes.last' = 0; 'changes.files' = 2
    } 'the pane opens on the agent scope with the newest turn selected'
    Equal $s['changes.active'] true 'the toggle focuses the Changes pane'
    Equal $s['changes.file.0.path'] 'a.txt' 'the newest turn lists a.txt first'
    Equal $s['changes.file.1.path'] 'b.txt' 'the newest turn lists b.txt second'
    if ([int]$s['changes.file.1.removed'] -le 0) { throw "b.txt removed expected > 0, observed $($s['changes.file.1.removed'])" }
    Write-Output 'PASS the deleted file shows removed lines'
    Equal $s['changes.file.0.added'] 1 'the newest turn shows only its own a.txt line'
    Equal $s['changes.file.0.marked'] false 'an edit before the turn began is not marked in it'

    # Shift+Down extends the selection to the older turn: one net diff per file over both turns.
    Aio key Shift+Down | Out-Null
    $s = Await-State @{ 'changes.first' = 0; 'changes.last' = 1; 'changes.files' = 3 } `
        'Shift+Down extends the selection over both turns'
    Equal $s['changes.file.0.path'] 'a.txt' 'the run lists a.txt'
    Equal $s['changes.file.1.path'] 'b.txt' 'the run lists b.txt'
    Equal $s['changes.file.2.path'] 'c.txt' 'the run lists c.txt'
    Equal $s['changes.file.0.added'] 3 'a.txt nets both agent lines and the edit between them'
    Equal $s['changes.file.0.marked'] true 'a.txt is marked as also changed between the turns'
    Equal $s['changes.file.1.marked'] false 'b.txt is not marked'
    Equal $s['changes.file.2.marked'] false 'c.txt, changed only in the first turn, is not marked'
    Aio capture --out "$data/agent-turns.png" | Out-Null

    # Uncommitted scope through the dropdown: Agent, Repository, then Uncommitted.
    Aio mouse click (Middle (Rect $s 'changes.scope_rect')) --px | Out-Null
    Await-State @{ 'changes.dropdown_open' = 'true' } 'the scope dropdown opens' | Out-Null
    Aio key Down Down Enter | Out-Null
    $s = Await-State @{ 'changes.scope' = 'uncommitted'; 'changes.files' = 3; 'changes.dropdown_open' = 'false' } `
        'Uncommitted shows a.txt, b.txt and c.txt'
    Equal $s['changes.file.0.path'] 'a.txt' 'a.txt is modified'
    Equal $s['changes.file.1.path'] 'b.txt' 'b.txt is deleted'
    Equal $s['changes.file.2.path'] 'c.txt' 'c.txt is untracked'

    Aio capture --out "$data/agent-changes.png" | Out-Null

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
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
