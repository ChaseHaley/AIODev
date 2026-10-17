[CmdletBinding()]
param()
. "$PSScriptRoot/compatibility_common.ps1"
$claude = Require-Application claude
& $claude --version
Start-Journey claude
try {
    Invoke-Aio run "& '$claude'"
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
    Invoke-Aio wait text 'U>' --timeout 10000
    Invoke-Aio run "Write-Output ('CLAUDE_' + 'RETURNED')"
    Invoke-Aio expect text CLAUDE_RETURNED
} finally { Invoke-Aio stop }
