[CmdletBinding()]
param()
. "$PSScriptRoot/compatibility_common.ps1"
$claude = Require-Application claude
& $claude --version
Start-Journey claude
try {
    # A journey started from inside Claude Code inherits its session markers, which change how the
    # child behaves; clear them so the journey sees a normal session.
    Invoke-Aio run "Get-ChildItem Env:CLAUDE* | Remove-Item; & '$claude'"
    Invoke-Aio wait text 'Claude Code' --timeout 20000
    $screen = & $ctl --name $name screen
    if ($screen -match 'trust this folder|trust the files') {
        Write-Output 'INCONCLUSIVE: Claude requires interactive workspace trust.'
        exit 2
    }
    Invoke-Aio type 'é界👩‍💻'
    Invoke-Aio wait text 'é界👩‍💻'
    Invoke-Aio resize 47x18
    Invoke-Aio wait text 'é界👩‍💻'
    Invoke-Aio resize 120x32
    Invoke-Aio key Ctrl+c Ctrl+c
    # Wait for the application to leave; an older prompt row can already show 'U>'.
    Invoke-Aio wait gone '⏵⏵' --timeout 10000
    Invoke-Aio wait idle
    Invoke-Aio wait text 'U>' --timeout 10000
    Invoke-Aio run "Write-Output ('CLAUDE_' + 'RETURNED')"
    Invoke-Aio expect text CLAUDE_RETURNED
} finally { Invoke-Aio stop }
