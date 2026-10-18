$ErrorActionPreference = 'Stop'
if (-not ('HeaderMouseCapture' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class HeaderMouseCapture {
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GetStdHandle(int id);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetConsoleMode(IntPtr handle, uint mode);
    public static void Run() {
        var input = GetStdHandle(-10);
        uint original;
        if (!GetConsoleMode(input, out original) || !SetConsoleMode(input, (original & ~0x57u) | 0x200u))
            throw new System.ComponentModel.Win32Exception();
        var bytes = new List<byte>();
        try {
            Console.Write("\x1b[?1003h\x1b[?1006h");
            Console.WriteLine("MS_READY");
            var stream = Console.OpenStandardInput();
            int value;
            while ((value = stream.ReadByte()) != -1 && value != 'q') bytes.Add((byte)value);
        } finally {
            Console.Write("\x1b[?1003l\x1b[?1006l");
            if (!SetConsoleMode(input, original)) throw new System.ComponentModel.Win32Exception();
        }
        Console.WriteLine("MOUSE_BYTES=" + (bytes.Count == 0 ? "none" : BitConverter.ToString(bytes.ToArray()).Replace("-", "")));
        var cell = System.Text.RegularExpressions.Regex.Match(System.Text.Encoding.ASCII.GetString(bytes.ToArray()), @"\x1b\[<\d+;(\d+);(\d+)[Mm]");
        if (cell.Success) Console.WriteLine("XY=" + cell.Groups[1].Value + "," + cell.Groups[2].Value);
    }
}
"@
}
[HeaderMouseCapture]::Run()
