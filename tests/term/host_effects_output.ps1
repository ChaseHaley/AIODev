# Emits every terminal-output effect that could plausibly reach the host: window title, hyperlink,
# bell and clipboard requests. It prints markers only, so a terminal that answers the clipboard read
# with host data would be visible as CLIPBOARD_REPLY instead of CLIPBOARD_SILENT.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$out = [Console]::OpenStandardOutput()
$escape = [char]27
$bell = [char]7
# Base64 of AIO_HOST_EFFECTS, the payload a clipboard write would carry.
$payload = 'QUlPX0hPU1RfRUZGRUNUUw=='
$uri = 'https://example.invalid/aio-host-effects'

function Emit([string] $text) {
    $out.Write([Text.Encoding]::UTF8.GetBytes($text))
    $out.Flush()
}

Emit "READY`r`n"
[void][Console]::ReadLine()
Emit "$escape[2J$escape[H"
Emit "$escape]2;AIO_HOST_EFFECTS$bell"
Emit "$escape]0;AIO_HOST_EFFECTS$bell"
Emit "$escape]8;;$uri$escape\AIO_LINK$escape]8;;$escape\`r`n"
Emit $bell
Emit "$escape]52;c;$payload$bell"
Emit "$escape]1337;Copy=:$payload$bell"
Emit "$escape]52;c;?$bell"
Emit "TRIGGERED`r`n"
# A terminal that serves the clipboard read writes its reply to this console input. Wait briefly so
# the marker reports what actually arrived instead of racing the reply.
$deadline = [DateTime]::UtcNow.AddMilliseconds(400)
$reply = $false
while ([DateTime]::UtcNow -lt $deadline) {
    if ([Console]::KeyAvailable) { $reply = $true; break }
    Start-Sleep -Milliseconds 10
}
if ($reply) { Emit "CLIPBOARD_REPLY`r`n" } else { Emit "CLIPBOARD_SILENT`r`n" }
Emit "DONE`r`n"
