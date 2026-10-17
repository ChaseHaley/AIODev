[CmdletBinding()]
param()
. "$PSScriptRoot/compatibility_common.ps1"
$null = Require-Application pwsh
Write-Output "PowerShell $($PSVersionTable.PSVersion); PSReadLine $((Get-Module PSReadLine -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version)"
Start-Journey powershell
try {
    Invoke-Aio type 'é界'
    Invoke-Aio expect cursor '6,0'
    Invoke-Aio key Left
    Invoke-Aio expect cursor '4,0'
    Invoke-Aio key Home
    Invoke-Aio expect cursor '3,0'
    Invoke-Aio key End
    Invoke-Aio expect cursor '6,0'
    Invoke-Aio key Backspace
    Invoke-Aio expect text 'U> é'
    Invoke-Aio expect cursor '4,0'
    Invoke-Aio key Ctrl+c
    Invoke-Aio run Clear-Host
    Invoke-Aio type 'é界👩‍💻'
    Invoke-Aio expect text 'U> é界👩‍💻'
    Invoke-KnownLimit 'PSReadLine measures a ZWJ emoji sequence per codepoint, so its cursor lands past the cluster' {
        Invoke-Aio expect cursor '8,0'
        Invoke-Aio key Left
        Invoke-Aio expect cursor '6,0'
        Invoke-Aio key Right
        Invoke-Aio expect cursor '8,0'
    }
    Invoke-Aio key End
    Invoke-KnownLimit 'PSReadLine Backspace removes one codepoint of a ZWJ sequence, not the cluster' {
        Invoke-Aio key Backspace
        Invoke-Aio expect text 'U> é界'
        Invoke-Aio expect no-text '👩'
    }
    Invoke-Aio resize 47x18
    Invoke-Aio expect text 'U> é界'
} finally { Invoke-Aio stop }
