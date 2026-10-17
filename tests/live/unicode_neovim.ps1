[CmdletBinding()]
param()
. "$PSScriptRoot/compatibility_common.ps1"
$nvim = Require-Application nvim
& $nvim --version | Select-Object -First 1
Start-Journey neovim
try {
    $fixture = New-UnicodeFixture
    Invoke-Aio run "Write-Output 'NVIM_HISTORY_MARKER'"
    Invoke-Aio run "& '$nvim' -u NONE -i NONE -n -c 'set mouse=a' '$fixture'"
    Invoke-Aio wait text 'latin.precomposed'
    Invoke-Aio expect no-text NVIM_HISTORY_MARKER
    Invoke-Aio expect state session.mouse=true
    Invoke-Aio key i
    Invoke-Aio type 'é界👩‍💻'
    Invoke-Aio wait text 'é界👩‍💻'
    Invoke-Aio key Esc
    Invoke-Aio type ':vsplit'
    Invoke-Aio key Enter
    Invoke-Aio mouse click '8,4'
    Invoke-Aio mouse drag '8,4' '16,4'
    Invoke-Aio mouse wheel '8,4' -3
    Invoke-Aio resize 47x18
    Invoke-Aio expect state grid.size=47x18
    Invoke-Aio resize 120x32
    Invoke-Aio key Esc
    Invoke-Aio type ':qa!'
    Invoke-Aio key Enter
    Invoke-Aio wait text 'NVIM_HISTORY_MARKER'
    Invoke-Aio expect state session.mouse=false
    Invoke-Aio expect text 'U>'
} finally { Invoke-Aio stop }
