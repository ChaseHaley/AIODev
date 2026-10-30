[CmdletBinding()]
param([switch] $CopyOnSelect)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = "claude-fullscreen-copy-$PID"
$data = Join-Path $repo "build/verify/$name"
$configDir = Join-Path $data 'claude'
$credentialPath = Join-Path $configDir '.credentials.json'
$claude = (Get-Command claude -ErrorAction Stop).Source
$sourceConfig = Join-Path $env:USERPROFILE '.claude.json'
$sourceCredentials = Join-Path $env:USERPROFILE '.claude/.credentials.json'
if (-not (Test-Path -LiteralPath $sourceCredentials)) {
    Write-Output 'INCONCLUSIVE: this journey requires an existing local Claude login.'
    exit 2
}

function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl failed: $result" }
    $result | Write-Output
}
function Screen { return (& $ctl --name $name screen) -join "`n" }
function State {
    $result = @{}
    foreach ($line in (& $ctl --name $name state)) {
        $pair = $line -split '=', 2
        if ($pair.Count -eq 2) { $result[$pair[0]] = $pair[1] }
    }
    return $result
}
function Assert-Equal($Actual, $Expected, [string] $Label) {
    if ($Actual -cne $Expected) { throw "${Label}: expected <$Expected>, got <$Actual>" }
    Write-Output "PASS $Label"
}
function Find-Text([string] $Text) {
    foreach ($line in ((Screen) -split "`n")) {
        if ($line -match '^\s*(\d+)\|(.*)$') {
            $row = [int]$Matches[1]
            $column = $Matches[2].IndexOf($Text, [StringComparison]::Ordinal)
            if ($column -ge 0) { return @($column, $row) }
        }
    }
    throw "Text is not visible: $Text"
}
function Select-Text([string] $Text, [int] $Cells, [switch] $Native) {
    $position = Find-Text $Text
    $start = "$($position[0]),$($position[1])"
    $end = "$($position[0] + $Cells),$($position[1])"
    if ($Native) { Invoke-Aio mouse drag $start $end --mods Shift }
    else { Invoke-Aio mouse drag $start $end }
}
function Assert-Clipboard([string] $Expected, [string] $Label) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $actual = [string](Get-Clipboard -Raw)
        if ($actual.Replace("`r`n", "`n") -ceq $Expected.Replace("`r`n", "`n")) {
            Write-Output "PASS $Label"; return
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "${Label}: expected fixture <$Expected>, got <$actual>"
}

# Materialize every available format before the journey changes the Windows clipboard.
Add-Type -AssemblyName System.Windows.Forms
$previous = [Windows.Forms.Clipboard]::GetDataObject()
$saved = [Windows.Forms.DataObject]::new()
if ($null -ne $previous) {
    foreach ($format in $previous.GetFormats($false)) {
        $value = $previous.GetData($format, $false)
        if ($null -ne $value) { $saved.SetData($format, $false, $value) }
    }
}
$started = $false
$journeyError = $null
$cleanupErrors = [Collections.Generic.List[string]]::new()
try {
    Invoke-Aio launch --fresh
    $started = $true
    New-Item -ItemType Directory -Force $configDir | Out-Null
    $original = Get-Content -LiteralPath $sourceConfig -Raw | ConvertFrom-Json -AsHashtable
    $config = @{ hasCompletedOnboarding = $true; lastOnboardingVersion = '2.1.314';
        theme = 'dark'; copyOnSelect = $CopyOnSelect.IsPresent; oauthAccount = $original['oauthAccount'] }
    [IO.File]::WriteAllText((Join-Path $configDir '.claude.json'), ($config | ConvertTo-Json -Depth 20))
    [IO.File]::WriteAllText((Join-Path $configDir 'settings.json'), '{"tui":"fullscreen"}')
    Copy-Item -LiteralPath $sourceCredentials -Destination $credentialPath

    # Resume a synthetic local transcript: selection tests never need a model request or tool execution.
    $session = [guid]::NewGuid().ToString()
    $userId = [guid]::NewGuid().ToString()
    $slug = $repo -replace '[^a-zA-Z0-9]', '-'
    $projectDir = Join-Path $configDir "projects/$slug"
    New-Item -ItemType Directory -Force $projectDir | Out-Null
    $common = @{ isSidechain = $false; cwd = $repo; sessionId = $session; version = '2.1.314';
        timestamp = [DateTime]::UtcNow.ToString('o'); userType = 'external' }
    $user = $common.Clone()
    $user['type'] = 'user'; $user['uuid'] = $userId; $user['parentUuid'] = $null
    $user['message'] = @{ role = 'user'; content = 'Display the terminal clipboard fixture.' }
    $assistant = $common.Clone()
    $assistant['type'] = 'assistant'; $assistant['uuid'] = [guid]::NewGuid().ToString()
    $assistant['parentUuid'] = $userId
    $body = "AIO232 plain copy`nAIO232 é界🙂`nAIO232 multiline one`nAIO232 multiline two"
    $assistant['message'] = @{ id = 'msg_aiodev_clipboard_fixture'; type = 'message'; role = 'assistant';
        model = 'claude-opus-4-6'; content = @(@{ type = 'text'; text = $body });
        stop_reason = 'end_turn'; stop_sequence = $null; usage = @{ input_tokens = 0; output_tokens = 0 } }
    $records = @($user, $assistant) | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress }
    [IO.File]::WriteAllLines((Join-Path $projectDir "$session.jsonl"), $records, [Text.UTF8Encoding]::new($false))
    $escapedConfig = $configDir.Replace("'", "''")
    $escapedClaude = $claude.Replace("'", "''")
    Invoke-Aio run "Get-ChildItem Env:CLAUDE* | Remove-Item; `$env:CLAUDE_CODE_NO_FLICKER = '1'; `$env:CLAUDE_CONFIG_DIR = '$escapedConfig'; & '$escapedClaude' --setting-sources '' --resume '$session'"
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $screen = Screen
        if ($screen -match 'Quick safety check:') { Invoke-Aio key Down Enter }
        if ($screen -match 'AIO232 plain copy' -and (State)['session.mouse'] -eq 'true') { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ((Screen) -notmatch 'AIO232 plain copy') { throw 'Claude did not resume the local fixture transcript.' }
    Invoke-Aio focus in
    Assert-Equal (State)['session.mouse'] 'true' 'Claude fullscreen mouse capture'

    Set-Clipboard -Value 'AIO232_SENTINEL'
    Select-Text 'AIO232 plain copy' 17
    Assert-Equal (State)['session.selection'] 'none' 'application owns ordinary drag selection'
    if ($CopyOnSelect) { Assert-Clipboard 'AIO232 plain copy' 'Claude copy-on-select reaches Windows clipboard' }
    else {
        Start-Sleep -Milliseconds 250
        Assert-Equal (Get-Clipboard -Raw) 'AIO232_SENTINEL' 'Claude copy-on-select disabled'
    }
    Invoke-Aio key Ctrl+Shift+C
    Assert-Clipboard 'AIO232 plain copy' 'Claude manual copy reaches Windows clipboard'
    Select-Text 'AIO232 plain copy' 17
    Invoke-Aio capture --out (Join-Path $data 'before-extension.png')
    Invoke-Aio key Shift+Left
    Invoke-Aio wait idle
    Invoke-Aio capture --out (Join-Path $data 'after-extension.png')
    Write-Output 'INFO keyboard extension captured for visual inspection; encoding is covered by app tests.'
    Select-Text 'AIO232 é界🙂' 12
    Invoke-Aio key Ctrl+Shift+C
    Assert-Clipboard 'AIO232 é界🙂' 'Claude Unicode selection copies exactly'
    Invoke-Aio capture --out (Join-Path $data 'claude-selection.png')

    Select-Text 'AIO232 plain copy' 17 -Native
    if ((State)['session.selection'] -eq 'none') { throw 'Shift-drag did not create a native selection.' }
    Invoke-Aio key Ctrl+Shift+C
    Assert-Clipboard 'AIO232 plain copy' 'Shift-drag native selection still copies'
    Assert-Equal (State)['session.selection'] 'none' 'native explicit copy clears selection'

    Invoke-Aio command terminal.find
    Invoke-Aio type 'AIO232 find é界🙂'
    Invoke-Aio key Ctrl+A Ctrl+Shift+C
    Assert-Clipboard 'AIO232 find é界🙂' 'Find field retains copy shortcut ownership'
    Invoke-Aio key Esc

    foreach ($key in @('Ctrl+Shift+V', 'Shift+Insert')) {
        Set-Clipboard -Value "AIO232paste é界🙂`nsecond line"
        Invoke-Aio key $key
        Invoke-Aio wait text 'second line' --timeout 5000
        if ((Screen) -notmatch 'AIO232paste é界🙂') { throw "Unicode paste failed through $key" }
        Invoke-Aio key Ctrl+U Backspace Ctrl+U
        Write-Output "PASS $key inserts multiline Unicode without submitting"
    }
    Invoke-Aio type 'AIO232 newline'
    Invoke-Aio key Shift+Enter
    Invoke-Aio type 'second draft line'
    Invoke-Aio wait text 'second draft line' --timeout 5000
    Invoke-Aio key Ctrl+U Backspace Ctrl+U
    Invoke-Aio resize 80x24
    Invoke-Aio wait text 'AIO232 plain copy' --timeout 5000
    Invoke-Aio resize 120x32
    Write-Output 'PASS Shift+Enter and fullscreen resize'

    Invoke-Aio command pane.split_right
    Invoke-Aio command pane.focus_left
    Invoke-Aio wait text 'AIO232 plain copy' --timeout 5000
    Select-Text 'AIO232 plain copy' 17
    Invoke-Aio key Ctrl+Shift+C
    Assert-Clipboard 'AIO232 plain copy' 'Claude copy works inside a split pane'

    Set-Clipboard -Value (("AIO232 large paste é界🙂`n") * 8)
    Invoke-Aio key Ctrl+Shift+V
    Invoke-Aio wait text 'Pasted text' --timeout 5000
    Write-Output 'PASS large multiline paste stays in the draft'

    Add-Type -AssemblyName System.Drawing
    $bitmap = [Drawing.Bitmap]::new(32, 32)
    try {
        [Windows.Forms.Clipboard]::SetImage($bitmap)
        Invoke-Aio key Alt+V
        Invoke-Aio wait text '[Image #' --timeout 5000
        Write-Output 'PASS Alt+V remains available for Claude image paste'
    } finally { $bitmap.Dispose() }
} catch { $journeyError = $_ }
finally {
    try {
        if ($started) {
            & $ctl --name $name stop | Write-Output
            if ($LASTEXITCODE -ne 0) { $cleanupErrors.Add('Could not stop the owned verification app.') }
        }
    } catch { $cleanupErrors.Add("App cleanup: $($_.Exception.Message)") }
    try {
        if (Test-Path -LiteralPath $credentialPath) { Remove-Item -LiteralPath $credentialPath -Force }
    } catch { $cleanupErrors.Add("Credential cleanup: $($_.Exception.Message)") }
    try {
        if ($null -eq $previous) { [Windows.Forms.Clipboard]::Clear() }
        else { [Windows.Forms.Clipboard]::SetDataObject($saved, $true) }
    } catch { $cleanupErrors.Add("Clipboard restoration: $($_.Exception.Message)") }
}
if ($cleanupErrors.Count -gt 0) {
    if ($null -ne $journeyError) { $cleanupErrors.Insert(0, "Journey: $($journeyError.Exception.Message)") }
    throw ($cleanupErrors -join "`n")
}
if ($null -ne $journeyError) { throw $journeyError }
