[CmdletBinding()]
param()
. "$PSScriptRoot/compatibility_common.ps1"
$codex = Require-Application codex
& $codex --version
Start-Journey codex
try {
    Invoke-Aio run "& '$codex'"
    Invoke-Aio wait text 'OpenAI Codex' --timeout 20000
    $screen = & $ctl --name $name screen
    if ($screen -match 'trust this|trust the|Sign in|sign in') {
        Write-Output 'INCONCLUSIVE: Codex requires interactive setup.'
        exit 2
    }
    Invoke-Aio type 'é界👩‍💻'
    Invoke-Aio wait text 'é界'
    Invoke-KnownLimit 'the Codex input box drops the emoji of a typed ZWJ sequence' {
        Invoke-Aio wait text 'é界👩‍💻'
    }
    Invoke-Aio resize 47x18
    Invoke-Aio wait text 'é界'
    Invoke-Aio resize 120x32
    Invoke-Aio key Ctrl+c Ctrl+c
    # Wait for the application to leave; an older prompt row can already show 'U>'.
    Invoke-Aio wait gone 'OpenAI Codex' --timeout 10000
    Invoke-Aio wait idle
    Invoke-Aio wait text 'U>' --timeout 10000
    Invoke-Aio run "Write-Output ('CODEX_' + 'RETURNED')"
    Invoke-Aio expect text CODEX_RETURNED
} finally { Invoke-Aio stop }
