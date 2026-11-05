# Speaks the Kitty graphics protocol from inside a pane, the way a real program does: through the
# console, so every byte crosses ConPTY in both directions.
param([Parameter(Mandatory)] [ValidateSet('probe', 'chunked', 'png', 'moves', 'delete')] [string] $Mode)
$ErrorActionPreference = 'Stop'
$esc = [char]27
$output = [Console]::OpenStandardOutput()
function Send([string] $Text) {
    $bytes = [Text.Encoding]::ASCII.GetBytes($Text)
    $output.Write($bytes, 0, $bytes.Length)
    $output.Flush()
}
switch ($Mode) {
    'probe' {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class KittyRawInput {
 [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
 [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
 [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
}
"@
        $handle = [KittyRawInput]::GetStdHandle(-10)
        [uint32] $mode = 0
        if (![KittyRawInput]::GetConsoleMode($handle, [ref] $mode)) { throw 'GetConsoleMode' }
        if (![KittyRawInput]::SetConsoleMode($handle, 0x200)) { throw 'SetConsoleMode' }
        $stdin = [Console]::OpenStandardInput()
        # A reply is printable once its leading escape is dropped. It ends at the given byte.
        function Read-Reply([byte] $End) {
            $text = [Text.StringBuilder]::new()
            $buffer = [byte[]]::new(1)
            do {
                if ($stdin.Read($buffer, 0, 1) -eq 0) { break }
                if ($buffer[0] -ne 27) { [void] $text.Append([char] $buffer[0]) }
            } while ($buffer[0] -ne $End)
            return $text.ToString()
        }
        try {
            Send "$esc`_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA$esc\"
            $query = Read-Reply ([byte][char]'\')
            Send "$esc[16t"
            $cell = Read-Reply ([byte][char]'t')
        } finally {
            [void] [KittyRawInput]::SetConsoleMode($handle, $mode)
        }
        [Console]::WriteLine("QUERY:$query")
        [Console]::WriteLine("CELL:$cell")
        [Console]::WriteLine('PROBE_DONE')
    }
    'chunked' {
        # 200x100 RGBA in four quadrants, large enough that base64 needs many protocol chunks.
        $width, $height = 200, 100
        $pixels = [byte[]]::new($width * $height * 4)
        for ($y = 0; $y -lt $height; $y++) {
            for ($x = 0; $x -lt $width; $x++) {
                $at = ($y * $width + $x) * 4
                if ($y -lt 50) { $color = if ($x -lt 100) { 255, 0, 0 } else { 0, 255, 0 } }
                else { $color = if ($x -lt 100) { 0, 0, 255 } else { 255, 255, 255 } }
                $pixels[$at], $pixels[$at + 1], $pixels[$at + 2], $pixels[$at + 3] = $color[0], $color[1], $color[2], 255
            }
        }
        $data = [Convert]::ToBase64String($pixels)
        $chunks = 0
        for ($at = 0; $at -lt $data.Length; $at += 4096) {
            $part = $data.Substring($at, [Math]::Min(4096, $data.Length - $at))
            $more = if ($at + 4096 -lt $data.Length) { 1 } else { 0 }
            $control = if ($at -eq 0) { "a=T,f=32,s=$width,v=$height,i=42,C=1,q=2,m=$more" } else { "m=$more" }
            Send "$esc`_G$control;$part$esc\"
            $chunks++
        }
        [Console]::WriteLine("CHUNKS:$chunks")
        [Console]::WriteLine('CHUNKED_DONE')
    }
    'png' {
        # A 2x1 PNG, red then green, scaled to eight cells by four.
        $png = 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP4z8DA8J8BAAf/Af8Bf4mnAAAAAElFTkSuQmCC'
        Send "$esc`_Ga=T,f=100,i=43,c=8,r=4,C=1,q=2;$png$esc\"
        [Console]::WriteLine('PNG_DONE')
    }
    'moves' {
        # The protocol's default: the terminal moves the cursor past the image, unseen by conhost.
        $png = 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP4z8DA8J8BAAf/Af8Bf4mnAAAAAElFTkSuQmCC'
        Send "$esc`_Ga=T,f=100,i=44,c=8,r=4,q=2;$png$esc\"
        Send "`r`n"
        [Console]::WriteLine('MOVES_DONE')
    }
    'delete' {
        Send "$esc`_Ga=d,d=A,q=2;$esc\"
        [Console]::WriteLine('DELETE_DONE')
    }
}
