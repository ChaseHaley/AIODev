Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RawInput {
 [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
 [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
 [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
}
"@
$h=[RawInput]::GetStdHandle(-10)
[uint32]$mode=0
if (![RawInput]::GetConsoleMode($h,[ref]$mode)) { throw 'GetConsoleMode' }
try {
 if (![RawInput]::SetConsoleMode($h,0x200)) { throw 'SetConsoleMode' }
 [Console]::Write(([char]27)+'[>1u')
 [Console]::WriteLine('KITTY_READY')
 $bytes=New-Object byte[] 64
 $stream=[Console]::OpenStandardInput()
 $n=0
 do {
  $read=$stream.Read($bytes,$n,64-$n)
  if ($read -eq 0) { break }
  $n+=$read
 } while ($n -lt 64 -and $bytes[$n-1] -ne 13 -and $bytes[$n-1] -ne 117)
 [Console]::WriteLine('RAW_HEX:'+([BitConverter]::ToString($bytes,0,$n)))
} finally {
 [Console]::Write(([char]27)+'[<u')
 [void][RawInput]::SetConsoleMode($h,$mode)
}
