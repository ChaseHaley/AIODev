[CmdletBinding()]
param(
    [string] $Name,
    [Alias('Pid')] [uint32] $ProcessId,
    [string] $Shot,
    [switch] $Frame,
    [AllowEmptyString()] [string] $Text,
    [string] $Keys,
    [string] $Chord,
    [AllowEmptyString()] [string] $SendText,
    [ValidateSet('move', 'down', 'up', 'drag', 'wheel')] [string] $Mouse,
    [int] $X = 0,
    [int] $Y = 0,
    [int] $X2 = 0,
    [int] $Y2 = 0,
    [int] $Delta = 120,
    [switch] $Pointer,
    [string] $Resize,
    [switch] $Activate
)

$ErrorActionPreference = 'Stop'
try {
    if ($PSBoundParameters.ContainsKey('Name') -eq $PSBoundParameters.ContainsKey('ProcessId')) {
        throw 'supply exactly one of -Name <instance> or -Pid <pid>'
    }
    $actions = @('Shot', 'Text', 'Keys', 'Chord', 'SendText', 'Mouse', 'Resize') |
        Where-Object { $PSBoundParameters.ContainsKey($_) }
    if (@($actions).Count -ne 1) {
        throw 'supply one action: -Shot, -Text, -Keys, -Chord, -SendText, -Mouse, -Resize'
    }
    $action = @($actions)[0]
    if (($action -eq 'Chord' -or $action -eq 'SendText') -and -not $Activate) {
        throw 'SendInput requires foreground focus; add -Activate or use -Text / -Keys for posted input'
    }
    if ($Activate -and $action -ne 'Chord' -and $action -ne 'SendText') {
        throw 'use -Activate only with -Chord or -SendText'
    }
    if ($Pointer -and $action -ne 'Mouse') { throw 'use -Pointer only with -Mouse' }
    if ($Frame -and $action -ne 'Shot') { throw 'use -Frame only with -Shot' }
    $repo = Split-Path $PSScriptRoot -Parent
    $record = @{}
    if ($Name) {
        if ($Name -cnotmatch '^[A-Za-z0-9_-]{1,32}$') {
            throw 'use a name of 1..32 ASCII letters, digits, hyphens, or underscores'
        }
        $recordPath = Join-Path $repo "build\verify\$Name\instance.ini"
        if (-not [IO.File]::Exists($recordPath)) {
            throw "no recorded instance $Name; run aioctl --name $Name launch"
        }
        foreach ($line in [IO.File]::ReadAllLines($recordPath)) {
            $parts = $line.Split([char[]]'=', 2, [StringSplitOptions]::None)
            if ($parts.Length -ne 2 -or $record.ContainsKey($parts[0])) {
                throw 'invalid instance.ini; run aioctl doctor'
            }
            $record[$parts[0]] = $parts[1]
        }
        $ProcessId = [uint32]$record['pid']
    }
    if ($ProcessId -eq 0) { throw 'supply a positive PID or run aioctl launch first' }
    $process = [Diagnostics.Process]::GetProcessById($ProcessId)
    try {
        $null = $process.Handle
        if ($process.HasExited) { throw 'recorded process exited; run aioctl launch' }
        $assemblies = @('System.Drawing')
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $assemblies += 'Microsoft.Win32.Primitives', 'System.Drawing.Primitives', 'System.Drawing.Common'
            foreach ($assemblyName in @('System.Private.Windows.GdiPlus.dll', 'System.Private.Windows.Core.dll')) {
                $assemblyPath = Join-Path $PSHOME $assemblyName
                if (Test-Path -LiteralPath $assemblyPath) { $assemblies += $assemblyPath }
            }
        }
        Add-Type -ReferencedAssemblies $assemblies -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
public static class AioWin32 {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public UIntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public UIntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Explicit)] public struct InputUnion {
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public MOUSEINPUT mi;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public InputUnion data; }
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder path, ref uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern void SetLastError(uint code);
    [DllImport("user32.dll", SetLastError=true)]
    static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", SetLastError=true)]
    static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)]
    static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", SetLastError=true)]
    static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", SetLastError=true)]
    static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll", SetLastError=true)]
    static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")]
    static extern uint MapVirtualKeyW(uint code, uint type);
    [DllImport("user32.dll", SetLastError=true)]
    static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError=true)]
    static extern IntPtr SendMessageTimeoutW(IntPtr h, uint message, UIntPtr w, IntPtr l,
        uint flags, uint timeout, out UIntPtr result);
    [DllImport("kernel32.dll")]
    static extern uint GetCurrentProcessId();
    [DllImport("user32.dll", SetLastError=true)]
    static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll", SetLastError=true)]
    static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", SetLastError=true)]
    static extern bool SetWindowPos(
        IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    static void Check(bool ok, string call) {
        if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error(),
            call + " failed; check PID and desktop access");
    }
    public static string ImagePath(IntPtr process) {
        StringBuilder path = new StringBuilder(32768);
        uint size = (uint)path.Capacity;
        Check(QueryFullProcessImageNameW(process, 0, path, ref size), "QueryFullProcessImageNameW");
        return path.ToString();
    }
    public static IntPtr Find(uint pid) {
        IntPtr found = IntPtr.Zero;
        SetLastError(0);
        bool ok = EnumWindows((h, p) => {
            uint id;
            Check(GetWindowThreadProcessId(h, out id) != 0, "GetWindowThreadProcessId");
            if (id == pid && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        if (found == IntPtr.Zero) {
            if (!ok && Marshal.GetLastWin32Error() != 0) Check(false, "EnumWindows");
            throw new Exception("no visible window for PID; run aioctl tray open and retry");
        }
        return found;
    }
    public static string Shot(IntPtr h, string path, bool frame) {
        RECT r;
        if (frame) Check(GetWindowRect(h, out r), "GetWindowRect");
        else Check(GetClientRect(h, out r), "GetClientRect");
        int width = r.right-r.left, height = r.bottom-r.top;
        if (width <= 0 || height <= 0) throw new Exception("empty client area; restore the window and retry");
        using (Bitmap bitmap = new Bitmap(width, height))
        using (Graphics g = Graphics.FromImage(bitmap)) {
            IntPtr dc = g.GetHdc();
            try { Check(PrintWindow(h, dc, frame ? 2u : 3u), "PrintWindow"); }
            finally { g.ReleaseHdc(dc); }
            bitmap.Save(path, ImageFormat.Png);
        }
        return width + "x" + height + " " + path;
    }
    static void Post(IntPtr h, uint message, long w, long l) {
        Check(PostMessageW(h, message, (IntPtr)w, (IntPtr)l), "PostMessageW");
    }
    public static void Text(IntPtr h, string text) {
        foreach (char c in text) Post(h, 0x102, c, 1);
    }
    static uint Scan(ushort vk) {
        if (vk == 0 || vk > 254) throw new Exception("virtual keys must be 1..254; use decimal or 0xNN");
        uint scan = MapVirtualKeyW(vk, 4);
        if (scan == 0) throw new Exception("MapVirtualKeyW found no scan code; choose a keyboard key");
        return scan;
    }
    static bool Extended(ushort vk, uint scan) {
        return (scan & 0xff00) == 0xe000 || (vk >= 0x21 && vk <= 0x28) || vk == 0x2d || vk == 0x2e;
    }
    public static ushort[] Keys(string text, char separator) {
        string[] parts = text.Split(new char[] { separator }, StringSplitOptions.None);
        ushort[] keys = new ushort[parts.Length];
        for (int i = 0; i < parts.Length; ++i) {
            string s = parts[i].Trim();
            keys[i] = s.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ?
                Convert.ToUInt16(s.Substring(2), 16) : Convert.ToUInt16(s, 10);
            Scan(keys[i]);
        }
        return keys;
    }
    public static void PostKeys(IntPtr h, ushort[] keys) {
        foreach (ushort vk in keys) {
            uint scan = Scan(vk);
            long bits = 1 | ((long)(scan & 255) << 16) | (Extended(vk, scan) ? 1L << 24 : 0);
            Post(h, 0x100, vk, bits);
            Post(h, 0x101, vk, bits | (3L << 30));
        }
    }
    static string WindowIdentity(IntPtr h) {
        uint pid;
        uint thread = GetWindowThreadProcessId(h, out pid);
        return h + "/pid=" + pid + "/tid=" + thread;
    }
    public static string Activate(IntPtr h) {
        var timer = System.Diagnostics.Stopwatch.StartNew();
        IntPtr before = GetForegroundWindow();
        bool accepted = SetForegroundWindow(h);
        IntPtr immediate = GetForegroundWindow(), final = immediate;
        string completion = "not-needed";
        int error = 0;
        if (accepted && immediate != h) {
            // Cross-queue activation is asynchronous; WM_NULL waits without granting foreground rights.
            // https://devblogs.microsoft.com/oldnewthing/20161118-00/?p=94745
            UIntPtr result;
            SetLastError(0);
            bool responsive = SendMessageTimeoutW(h, 0, UIntPtr.Zero, IntPtr.Zero,
                0x22, 2000, out result) != IntPtr.Zero; // ABORTIFHUNG | ERRORONEXIT
            if (!responsive) error = Marshal.GetLastWin32Error();
            completion = responsive ? "processed" : "failed";
            final = GetForegroundWindow();
        }
        string trace = "SetForegroundWindow=" + accepted + " callerPid=" + GetCurrentProcessId() +
            " target=" + WindowIdentity(h) + " before=" + WindowIdentity(before) +
            " immediate=" + WindowIdentity(immediate) + " final=" + WindowIdentity(final) +
            " completion=" + completion + " completionError=" + error + " elapsedMs=" + timer.ElapsedMilliseconds;
        if (!accepted) throw new Exception("activation request refused; no input sent; " + trace);
        if (completion == "failed") throw new Exception("activation completion check failed; no input sent; " + trace);
        if (final != h) throw new Exception("target did not retain foreground; no input sent; " + trace);
        return trace;
    }
    static INPUT Key(ushort vk, bool up) {
        uint scan = Scan(vk);
        INPUT input = new INPUT(); input.type = 1;
        input.data.ki.wVk = vk; input.data.ki.wScan = (ushort)(scan & 255);
        input.data.ki.dwFlags = (up ? 2u : 0u) | (Extended(vk, scan) ? 1u : 0u);
        return input;
    }
    static void Send(IntPtr h, INPUT[] inputs) {
        if (GetForegroundWindow() != h)
            throw new Exception("target lost foreground focus; retry with -Activate");
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
        if (sent != inputs.Length)
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "SendInput incomplete; check integrity level and focus");
    }
    public static void Chord(IntPtr h, ushort[] keys) {
        INPUT[] inputs = new INPUT[keys.Length*2];
        for (int i = 0; i < keys.Length; ++i) {
            inputs[i] = Key(keys[i], false);
            inputs[inputs.Length-1-i] = Key(keys[i], true);
        }
        try { Send(h, inputs); }
        catch {
            INPUT[] releases = new INPUT[keys.Length];
            for (int i = 0; i < keys.Length; ++i) releases[i] = Key(keys[keys.Length-1-i], true);
            uint released = SendInput((uint)releases.Length, releases, Marshal.SizeOf(typeof(INPUT)));
            if (released != releases.Length)
                throw new Exception("SendInput and key release failed; release modifiers manually");
            throw;
        }
    }
    public static void SendText(IntPtr h, string text) {
        foreach (char c in text) {
            INPUT down = new INPUT(); down.type = 1; down.data.ki.wScan = c; down.data.ki.dwFlags = 4;
            INPUT up = down; up.data.ki.dwFlags |= 2;
            Send(h, new INPUT[] { down, up });
        }
    }
    static IntPtr Pack(int x, int y) {
        if (x < -32768 || x > 32767 || y < -32768 || y > 32767)
            throw new Exception("coordinates must fit signed 16-bit message fields");
        return (IntPtr)((y << 16) | (x & 65535));
    }
    public static void Mouse(IntPtr h, string action, int x, int y, int x2, int y2, int delta, bool pointer) {
        POINT p = new POINT(); p.x = x; p.y = y;
        if (pointer || action == "wheel") Check(ClientToScreen(h, ref p), "ClientToScreen");
        if (pointer) Check(SetCursorPos(p.x, p.y), "SetCursorPos");
        long pos = Pack(x,y).ToInt64();
        if (action == "wheel") {
            if (delta < -32768 || delta > 32767) throw new Exception("wheel delta must fit signed 16 bits");
            Post(h, 0x20a, (long)delta << 16, Pack(p.x,p.y).ToInt64());
        } else if (action == "move") Post(h, 0x200, 0, pos);
        else if (action == "down") Post(h, 0x201, 1, pos);
        else if (action == "up") Post(h, 0x202, 0, pos);
        else {
            Pack(x2,y2);
            Post(h, 0x201, 1, pos);
            try {
                for (int i = 1; i <= 8; ++i) {
                    int cx = x+(x2-x)*i/8, cy = y+(y2-y)*i/8;
                    if (pointer) {
                        POINT point = new POINT(); point.x = cx; point.y = cy;
                        Check(ClientToScreen(h, ref point), "ClientToScreen");
                        Check(SetCursorPos(point.x, point.y), "SetCursorPos");
                    }
                    Post(h, 0x200, 1, Pack(cx,cy).ToInt64());
                }
            } finally { Post(h, 0x202, 0, Pack(x2,y2).ToInt64()); }
        }
    }
    public static void Resize(IntPtr h, int width, int height) {
        if (width < 1 || height < 1 || width > 32767 || height > 32767)
            throw new Exception("client dimensions must be 1..32767");
        RECT client, window;
        Check(GetClientRect(h, out client), "GetClientRect");
        Check(GetWindowRect(h, out window), "GetWindowRect");
        Check(SetWindowPos(h, IntPtr.Zero, 0, 0,
            width+window.right-window.left-client.right+client.left,
            height+window.bottom-window.top-client.bottom+client.top, 0x16), "SetWindowPos");
        Check(GetClientRect(h, out client), "GetClientRect");
        if (client.right-client.left != width || client.bottom-client.top != height)
            throw new Exception("window constrained the client size; choose another -Resize value");
    }
}
'@
        if ($Name) {
            $expected = Join-Path $repo 'build\aiodev-verify.exe'
            if ($record['executable'] -ine $expected -or [AioWin32]::ImagePath($process.Handle) -ine $expected -or
                $process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne [uint64]$record['created']) {
                throw 'PID identity differs from the launch record; run aioctl doctor before driving it'
            }
        }
        $previousDpi = [AioWin32]::SetThreadDpiAwarenessContext([IntPtr](-4))
        if ($previousDpi -eq [IntPtr]::Zero) {
            throw 'cannot set per-monitor DPI awareness; check desktop access'
        }
        try {
            $window = [AioWin32]::Find($ProcessId)
            switch ($action) {
                'Shot' { [AioWin32]::Shot($window, [IO.Path]::GetFullPath($Shot), $Frame.IsPresent) }
                'Text' {
                    [AioWin32]::Text($window, $Text)
                    "posted text chars=$($Text.Length) pid=$ProcessId"
                }
                'Keys' {
                    $virtualKeys = [AioWin32]::Keys($Keys, ',')
                    [AioWin32]::PostKeys($window, $virtualKeys)
                    "posted keys count=$($virtualKeys.Length) pid=$ProcessId"
                }
                'Chord' {
                    $virtualKeys = [AioWin32]::Keys($Chord, '+')
                    Write-Verbose ([AioWin32]::Activate($window))
                    [AioWin32]::Chord($window, $virtualKeys)
                    "sent chord keys=$($virtualKeys.Length) pid=$ProcessId"
                }
                'SendText' {
                    Write-Verbose ([AioWin32]::Activate($window))
                    [AioWin32]::SendText($window, $SendText)
                    "sent text chars=$($SendText.Length) pid=$ProcessId"
                }
                'Mouse' {
                    [AioWin32]::Mouse($window, $Mouse, $X, $Y, $X2, $Y2, $Delta, $Pointer.IsPresent)
                    $warning = ''
                    if (($Mouse -eq 'move' -or $Mouse -eq 'drag') -and -not $Pointer) {
                        $warning = '; warn mouse leave unless real pointer is over window; use -Pointer'
                    }
                    "posted mouse=$Mouse client=$X,$Y end=$X2,$Y2 delta=$Delta pid=$ProcessId$warning"
                }
                'Resize' {
                    if ($Resize -notmatch '^([0-9]{1,5})x([0-9]{1,5})$') {
                        throw 'use -Resize <width>x<height> in client pixels'
                    }
                    [AioWin32]::Resize($window, [int]$Matches[1], [int]$Matches[2])
                    "resized client=$Resize pid=$ProcessId"
                }
            }
        } finally {
            if ([AioWin32]::SetThreadDpiAwarenessContext($previousDpi) -eq [IntPtr]::Zero) {
                throw 'cannot restore thread DPI context; close this PowerShell session'
            }
        }
    } finally { $process.Dispose() }
} catch {
    [Console]::Error.WriteLine('error: ' + $_.Exception.GetBaseException().Message +
        '; check the target PID, action arguments, and output permissions')
    exit 1
}
