[CmdletBinding()]
param([string] $Name = 'lua_scripting')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$aio = Join-Path $repo 'build/aio.exe'
$work = Join-Path $repo "build/verify/$Name-files"
$captures = Join-Path $repo "build/verify/$Name-captures"
$settings = Join-Path $work 'settings.ini'
# aioctl recreates the instance's data directory on --fresh and writes settings.ini there.
$data = [IO.Path]::GetFullPath((Join-Path $repo "build/verify/$Name"))
$initLua = Join-Path $data 'init.lua'
$dataSettings = Join-Path $data 'settings.ini'

function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    return $out
}
function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Aio state)) {
        $at = $line.IndexOf('=')
        if ($at -gt 0) { $state[$line.Substring(0, $at)] = $line.Substring($at + 1) }
    }
    return $state
}
function Wait-For([string] $Key, [string] $Value) {
    for ($i = 0; $i -lt 50; $i++) {
        if ((Read-State)[$Key] -eq $Value) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for $Key=$Value; saw $((Read-State)[$Key])."
}
function Wait-Until([scriptblock] $Test, [string] $What) {
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        if (& $Test) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for $What."
}
function Shot([string] $Label) {
    Invoke-Aio capture --out (Join-Path $captures "$Label.png") | Out-Null
}
function Ok([string] $Step) { Write-Output "ok: $Step" }
# Lua files get UTF-8 without a byte order mark, so the first line is Lua.
function Write-Lua([string] $Path, [string] $Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

# Runs build/aio.exe with stdout and stderr merged, and returns its exit code and text without throwing.
function Invoke-Cli {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $aio @args 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $saved }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out) -join "`n").Trim() }
}
# aio against this instance; throws unless it exits 0.
function Aio {
    $r = Invoke-Cli --instance $Name @args
    if ($r.Code -ne 0) { throw "aio $($args -join ' ') exited $($r.Code): $($r.Text)" }
    return $r.Text
}
function Tab-Names { @((Aio --json tab.list | ConvertFrom-Json).tabs | ForEach-Object { $_.name }) }
function Pane-Rect([uint32] $Id) {
    $pane = (Aio --json pane.list | ConvertFrom-Json).panes | Where-Object { $_.id -eq $Id }
    if (-not $pane) { throw "pane.list has no pane $Id." }
    return $pane.rect
}
function Created-Count {
    $reply = Aio exec created_count | ConvertFrom-Json
    if ($null -eq $reply.count) { throw "created_count returned no count: $reply" }
    return [int]$reply.count
}

Remove-Item -LiteralPath $work, $captures -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work, $captures | Out-Null
@"
control.enabled = true
shell.command = pwsh.exe -NoLogo -NoProfile -NoExit
cursor.blink = true
window.columns = 170
window.rows = 50
"@ | Set-Content -LiteralPath $settings -Encoding utf8

# A bare aio inside another AIODev pane targets that pane's instance and pane; this journey drives its own.
$savedPane = $env:AIODEV_PANE
Remove-Item Env:AIODEV_PANE -ErrorAction SilentlyContinue

Invoke-Aio launch --fresh --settings $settings | Out-Null
try {
    Invoke-Aio wait text 'PS ' | Out-Null

    # 1. The configuration: actions, a binding with arguments, an event counter, a mode, a runaway
    # action and one that changes a setting.
    $lua = @'
aio.action{name = 'hello_tab', title = 'Open hello tab', args = {name = 'string?'}, run = function(ctx, args)
	local name = (args or {}).name or 'hello'
	local r = aio.tab.new{name = name, tab_name = name}
	return {pane = r and r.pane}
end}
aio.bind('Ctrl+Alt+H', 'hello_tab', {name = 'from_key'})

local created = 0
aio.on('pane.created', function() created = created + 1 end)
aio.action{name = 'created_count', title = 'Count created panes', run = function() return {count = created} end}

aio.mode('resize', {exclusive = true})
aio.bind('Ctrl+Alt+R', 'mode.enter', {name = 'resize'})
aio.bind('resize/Left', 'pane.resize', {direction = 'left', cells = 2})

aio.action{name = 'spin', title = 'Spin forever', run = function() while true do end end}
aio.action{name = 'set_blink', title = 'Turn cursor blink off', run = function()
	aio.settings.set('cursor.blink', 'false')
	return aio.settings.get('cursor.blink')
end}
'@
    Write-Lua $initLua $lua
    Invoke-Aio command settings.reload | Out-Null
    Ok 'init.lua written and settings reloaded'

    # 2. Actions join the command list with their titles.
    Wait-Until {
        @((Aio --json commands | ConvertFrom-Json).commands |
            Where-Object { $_.name -eq 'hello_tab' -and $_.title -eq 'Open hello tab' }).Count -eq 1
    } 'aio commands to list hello_tab titled Open hello tab'
    Ok 'commands lists hello_tab'

    # 3. aio exec runs an action with key=value arguments and prints its result.
    $text = Aio exec hello_tab name=journey
    $reply = $text | ConvertFrom-Json
    if (-not $reply.pane) { throw "exec hello_tab printed no pane id: $text" }
    Wait-Until { (Tab-Names) -contains 'journey' } "a tab named journey; saw $((Tab-Names) -join ', ')"
    Ok "exec hello_tab opened pane $($reply.pane) in tab journey"

    # 4. A key bound to an action with arguments.
    Invoke-Aio key Ctrl+Alt+H | Out-Null
    Wait-Until { (Tab-Names) -contains 'from_key' } "Ctrl+Alt+H to open tab from_key; saw $((Tab-Names) -join ', ')"
    Ok 'Ctrl+Alt+H opened tab from_key'

    # 5. The pane.created handler saw both tabs.
    $count = Created-Count
    if ($count -lt 2) { throw "created_count reported $count pane.created events; expected at least 2." }
    Ok "created_count reported $count"

    # 6. An exclusive mode: Left resizes while it is active and stops once Esc leaves it.
    $split = Aio --json pane.split --direction right | ConvertFrom-Json
    if (-not $split.pane) { throw 'pane.split returned no pane id.' }
    $splitId = [uint32]$split.pane
    Wait-Until { $null -ne (Pane-Rect $splitId) } "a rect for split pane $splitId"
    $before = (Pane-Rect $splitId).width
    Invoke-Aio key Ctrl+Alt+R | Out-Null
    Invoke-Aio key Left | Out-Null
    Wait-Until { (Pane-Rect $splitId).width -ne $before } "resize/Left to change pane $splitId's width from $before"
    $resized = (Pane-Rect $splitId).width
    Ok "resize mode Left changed width $before -> $resized"
    Invoke-Aio key Esc | Out-Null
    Invoke-Aio key Left | Out-Null
    Start-Sleep -Milliseconds 500
    $after = (Pane-Rect $splitId).width
    if ($after -ne $resized) { throw "Left still resized after Esc: width $resized -> $after." }
    Ok 'Esc left resize mode'

    # 7. aio.settings writes settings.ini in the data directory.
    $text = Aio exec set_blink
    $blink = $text | ConvertFrom-Json
    if ("$blink" -ne 'false') { throw "set_blink returned $text; expected false." }
    Wait-Until { (Get-Content -LiteralPath $dataSettings -Raw) -match '(?m)^\s*cursor\.blink\s*=\s*false\s*$' } `
        "cursor.blink = false in $dataSettings"
    Ok 'set_blink wrote cursor.blink = false'

    # 8. A runaway action is stopped by the budget and the app keeps answering.
    $spin = Invoke-Cli --instance $Name exec spin
    if ($spin.Code -eq 0) { throw "exec spin exited 0: $($spin.Text)" }
    if ($spin.Text -notmatch 'took longer than') { throw "exec spin did not name the budget: $($spin.Text)" }
    Ok "exec spin exited $($spin.Code) over budget"
    $count = Created-Count
    Ok "app alive after spin (created_count $count)"

    # 9. A script file waits for an event about a pane it started.
    $waitLua = Join-Path $work 'wait.lua'
    $lua = @'
-- The pane pauses a second before exiting 3, so the wait below has subscribed by then.
local r = assert(aio.pane.split{direction = 'right', command = {'cmd.exe', '/d', '/c', 'ping -n 2 127.0.0.1 >nul & exit 3'}})
local ev = assert(aio.wait('pane.exited', {pane = r.pane}, 10), 'pane ' .. tostring(r.pane) .. ' did not exit')
return {code = ev.exit_code}
'@
    Write-Lua $waitLua $lua
    $text = Aio exec $waitLua
    if (($text -replace '\s', '') -ne '{"code":3}') { throw "exec wait.lua printed $text; expected {`"code`":3}." }
    Ok 'exec wait.lua returned code 3'

    # 10. A top level that suspends still returns its value.
    $text = Aio exec -e 'aio.sleep(0.2) return 5'
    if ($text -ne '5') { throw "exec -e printed '$text'; expected 5." }
    Ok 'exec -e with aio.sleep returned 5'

    # 11. A broken init.lua keeps the last good load, and config check names the line.
    Write-Lua $initLua "-- broken on purpose`nlocal = 1`n"
    Invoke-Aio command settings.reload | Out-Null
    Start-Sleep -Milliseconds 300
    $text = Aio exec hello_tab name=still
    if (-not ($text | ConvertFrom-Json).pane) { throw "hello_tab after a broken reload printed no pane: $text" }
    Wait-Until { (Tab-Names) -contains 'still' } "a tab named still; saw $((Tab-Names) -join ', ')"
    Ok 'hello_tab still works after a broken reload'
    $check = Invoke-Cli config check --data-dir $data
    if ($check.Code -ne 1) { throw "config check exited $($check.Code); expected 1: $($check.Text)" }
    if ($check.Text -notmatch 'init\.lua:2') { throw "config check did not name init.lua:2: $($check.Text)" }
    Ok 'config check reported init.lua:2'

    # 12. Actions appear in the command palette.
    Invoke-Aio command app.command_palette | Out-Null
    Wait-For 'palette.open' 'true'
    Invoke-Aio type hello | Out-Null
    Wait-For 'palette.item' 'hello_tab'
    Shot 'palette-action'
    Invoke-Aio key Esc | Out-Null
    Wait-For 'palette.open' 'false'
    Ok 'palette lists hello_tab'

    Write-Output 'PASS lua_scripting journey'
} finally {
    & $ctl --name $Name stop | Out-Null
    if ($null -ne $savedPane) { $env:AIODEV_PANE = $savedPane }
}
