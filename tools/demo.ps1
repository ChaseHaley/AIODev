<#
.SYNOPSIS
Opens a clean AIODev instance laid out for recording a feature demo.

.DESCRIPTION
Starts AIODev as its own instance with settings and layout in build/demo, so the owner's sessions,
history and settings never appear on screen. Builds three tabs: a shell, a code tab (Neovim, Git
history and a simulated agent) and an agents tab with two more simulated agents. The simulated
agents report program status (OSC 7501) and stop to ask for approval, so the activity panel, tab
indicators and notifications have something to show. Press Enter in an agent pane to approve it.

.EXAMPLE
./tools/demo.ps1
#>
[CmdletBinding()]
param(
    [string] $Executable = 'build/release/aiodev.exe',
    [string] $Instance = 'demo',
    [int] $Width = 1600,
    [int] $Height = 900
)

$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
$app = Resolve-Path (Join-Path $repo $Executable)
$aio = Join-Path (Split-Path $app) 'aio.exe'
$data = Join-Path $repo 'build/demo'
. (Join-Path $PSScriptRoot 'instance.ps1')

if (Test-AIODevInstanceRunning $Instance) {
    throw "A '$Instance' instance is already running; quit it first."
}
if (Test-Path -LiteralPath $data) { Remove-Item -LiteralPath $data -Recurse -Force }
New-Item -ItemType Directory -Force $data | Out-Null

# A short prompt keeps user names and long paths out of the recording.
$promptScript = Join-Path $data 'prompt.ps1'
Set-Content -LiteralPath $promptScript -Value 'function prompt { "$(Split-Path -Leaf (Get-Location)) > " }'

$agent = Join-Path $data 'agent.ps1'
Set-Content -LiteralPath $agent -Value @'
param([string] $Name, [string] $Task, [string] $Question, [int] $Seconds = 8)
$escape = [char]27
function Report([string] $State, [string] $Message, [int] $Progress = -1) {
    $fields = "state=$($State):id=$($Name):app=$Name"
    if ($Message) { $fields += ':msg=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Message)) }
    if ($Progress -ge 0) { $fields += ":progress=$Progress" }
    [Console]::Write("$escape]7501;$fields$([char]7)")
}
function Step([string] $Text) { Write-Host "  $escape[2m$Text$escape[0m"; Start-Sleep -Milliseconds (Get-Random -Minimum 400 -Maximum 1100) }
while ($true) {
    Clear-Host
    Write-Host "$escape[1m$Name$escape[0m  $Task`n"
    Report working $Task 0
    $steps = @('Reading the workspace', 'Planning changes', 'Editing files', 'Running checks')
    for ($i = 0; $i -lt $steps.Count; $i++) {
        Step $steps[$i]
        Report working $steps[$i] ([int] (($i + 1) * 100 / ($steps.Count + 1)))
        Start-Sleep -Seconds ([int] ($Seconds / $steps.Count))
    }
    Write-Host "`n$escape[33m? $Question$escape[0m  (press Enter)"
    Report blocked $Question
    $null = Read-Host
    Step 'Approved; finishing up'
    Report working 'Finishing up' 90
    Start-Sleep -Seconds 2
    Write-Host "`n$escape[32m✓ Done$escape[0m"
    Report done $Task
    $null = Read-Host "`nPress Enter to run again"
}
'@

$pwsh = (Get-Command pwsh).Source
$shell = "`"$pwsh`" -NoLogo -NoExit -File `"$promptScript`""
Set-Content -LiteralPath (Join-Path $data $AIODevSettingsFile) -Value @(
    'control.enabled = true'
    "shell.command = `"$shell`""
    "shell.directory = `"$repo`""
    'status.panel = true'
)

$process = Start-Process -FilePath $app -ArgumentList (Get-AIODevInstanceArguments $Instance $data) -PassThru
$deadline = [DateTime]::UtcNow.AddSeconds(15)
do {
    if ([DateTime]::UtcNow -gt $deadline) { throw 'AIODev did not open a window.' }
    Start-Sleep -Milliseconds 100
    $process.Refresh()
} while ($process.MainWindowHandle -eq 0)

function Aio {
    $result = & $aio --instance $Instance @args
    if ($LASTEXITCODE -ne 0) { throw "aio $($args -join ' ') failed: $result" }
    return $result
}
function Agent([string] $Name, [string] $Task, [string] $Question, [int] $Seconds) {
    return @('--', $pwsh, '-NoLogo', '-NoProfile', '-File', $agent, '-Name', $Name, '-Task', $Task,
        '-Question', $Question, '-Seconds', $Seconds)
}

Aio pane.rename --pane 1 shell | Out-Null

$code = Aio tab.new --name code --focus '--' nvim src/main.odin
$history = Aio pane.split --pane $code --direction right --ratio 0.45 --name history '--' `
    $pwsh -NoLogo -NoExit -Command ". '$promptScript'; git --no-pager log --oneline --graph --decorate -n 400"
Aio pane.split --pane $history --direction down --name codex `
    @(Agent 'codex' 'Add scrollbar hover states' 'Run the UI test suite?' 10) | Out-Null

$claude = Aio tab.new --name agents @(Agent 'claude' 'Refactor pointer targets' 'Apply edits to 4 files?' 6)
Aio pane.split --pane $claude --direction right --name build `
    @(Agent 'build' 'Release build' 'Overwrite build/release?' 14) | Out-Null

Add-Type -Namespace AIODevDemo -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
'@
Add-Type -AssemblyName System.Windows.Forms
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
[void] [AIODevDemo.Native]::ShowWindow($process.MainWindowHandle, 1)
[void] [AIODevDemo.Native]::SetWindowPos($process.MainWindowHandle, [IntPtr]::Zero,
    $area.X + [int] (($area.Width - $Width) / 2), $area.Y + [int] (($area.Height - $Height) / 2), $Width, $Height, 0x0040)

Write-Output "Demo ready: instance '$Instance', window $($Width)x$Height, settings in $data"
