[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'confirmation-lifecycle'
$directory = Join-Path $repo "build/verify/$name"
$source = Join-Path $repo 'build/work213-confirmation-source.ini'
function Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}
function State {
    $s = @{}
    foreach ($line in (& $ctl --name $name state)) {
        $pair = $line -split '=', 2
        $s[$pair[0]] = $pair[1].Trim('"')
    }
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect confirmation state.' }
    return $s
}
function Equal($Actual, $Expected, $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Shot($Label) {
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Shot (Join-Path $directory "$Label.png") -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}
function Button($Which) {
    $s = State
    $size = $s['window.size'] -split 'x'
    $scale = [double]$s['window.scale']
    $width = [double]$size[0]
    $height = [double]$size[1]
    $panelWidth = [math]::Min(380 * $scale, $width - 32 * $scale)
    $x = ($width + $panelWidth) / 2 - 64 * $scale
    if ($Which -eq 'cancel') { $x -= 104 * $scale }
    $y = [math]::Max(24 * $scale, $height * 0.22) + 119 * $scale
    return "$([int]$x),$([int]$y)"
}
function Open-Swap {
    Aio command pane.change_shell
    Aio key Down Enter
    Equal (State)['swap.open'] true 'shell switch asks first'
    Start-Sleep -Milliseconds 200
    Equal (State)['swap.opacity'] 1 'shell switch finishes its opening animation'
}
@'
shell.command = pwsh.exe -NoLogo -NoProfile
cursor.blink = false
profile.alternate.name = Alternate
profile.alternate.command = cmd.exe /d
profile.order = default, alternate
'@ | Set-Content -LiteralPath $source -Encoding utf8
Aio launch --fresh --settings $source
try {
    Aio wait text 'PS '
    $session = (State)['session.id']
    Open-Swap
    Shot swap-dark
    Aio mouse down (Button accept) --px
    Aio mouse up '1,500' --px
    Equal (State)['swap.open'] true 'outside release preserves the shell question'
    Aio key Alt+D Esc
    Start-Sleep -Milliseconds 150
    Equal (State)['swap.opacity'] 0 'cancel finishes the shell fade'
    Equal (State)['swap.profile'] '' 'settled shell question releases its profile'
    Equal (State)['session.profile'] default 'cancel preserves the current profile'
    if ([IO.File]::ReadAllText((Join-Path $directory 'settings.ini')).Contains('pane.confirm_shell_switch = false')) {
        throw 'Cancel persisted the opt-out.'
    }
    Write-Output 'PASS cancel does not persist the opt-out'
    Open-Swap
    Aio mouse click '1,500' --px
    Equal (State)['swap.open'] false 'outside click cancels the shell question'
    Open-Swap
    Aio key Enter
    Equal (State)['session.profile'] alternate 'Enter switches the shell'
    Equal (State)['session.id'] $session 'switch retains session identity'
    Aio wait text '>'
    [IO.File]::AppendAllText((Join-Path $directory 'settings.ini'), "`ntheme.mode = light`n")
    Aio command settings.reload
    Aio command pane.change_shell
    Aio key Enter
    Start-Sleep -Milliseconds 200
    Equal (State)['swap.opacity'] 1 'reverse shell question opens'
    Shot swap-light
    Aio key Alt+D Enter
    Equal (State)['session.profile'] default 'reverse switch accepts'
    if (-not [IO.File]::ReadAllText((Join-Path $directory 'settings.ini')).Contains('pane.confirm_shell_switch = false')) {
        throw 'Accept did not persist the opt-out.'
    }
    Write-Output 'PASS accept persists the opt-out'
    Aio command pane.split_right
    Aio command tab.new
    Aio command tab.select_1
    Aio key Ctrl+Shift+W
    Start-Sleep -Milliseconds 200
    Equal (State)['confirm.opacity'] 1 'close question finishes its opening animation'
    Shot close-light
    Aio mouse down (Button accept) --px
    Aio mouse up '1,500' --px
    Equal (State)['confirm.open'] true 'outside release preserves the close question'
    Aio key Esc
    Start-Sleep -Milliseconds 150
    Equal (State)['confirm.opacity'] 0 'close question finishes its fade'
    Equal (State)['tabs.count'] 2 'cancel preserves the split tab'
    Aio key Ctrl+Shift+W Enter
    Equal (State)['tabs.count'] 1 'accept closes the split tab'
} finally {
    & $ctl --name $name stop | Write-Output
    if (Test-Path -LiteralPath $source) { Remove-Item -LiteralPath $source -Force }
}
