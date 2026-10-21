using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class TermBenchProcess : IDisposable {
    IntPtr job, process;
    public uint Id { get; private set; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Startup {
        public uint cb;
        public string reserved, desktop, title;
        public uint x, y, width, height, columns, rows, fill, flags;
        public ushort show, reservedSize;
        public IntPtr reservedData, input, output, error;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr process, thread; public uint id, threadId; }
    [StructLayout(LayoutKind.Sequential)]
    struct Limits {
        public long processTime, jobTime;
        public uint flags;
        public UIntPtr minWorkingSet, maxWorkingSet;
        public uint activeProcesses;
        public UIntPtr affinity;
        public uint priority, scheduling;
        public ulong readOps, writeOps, otherOps, readBytes, writeBytes, otherBytes;
        public UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Accounting {
        public long userTime, kernelTime, periodUserTime, periodKernelTime;
        public uint pageFaults, totalProcesses, activeProcesses, terminatedProcesses;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int kind, ref Limits limits, int size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryInformationJobObject(IntPtr job, int kind, out Accounting info, int size, IntPtr length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string app, StringBuilder command, IntPtr pa, IntPtr ta,
        bool inherit, uint flags, IntPtr environment, string directory, ref Startup startup, out ProcessInfo info);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    static Exception Error(string call) {
        int code = Marshal.GetLastWin32Error();
        return new Win32Exception(code, call + " Win32=" + code);
    }
    public bool HasExited {
        get {
            uint result = WaitForSingleObject(process, 0);
            if (result == 0xffffffff) throw Error("WaitForSingleObject");
            return result == 0;
        }
    }
    public static TermBenchProcess Launch(string executable, string arguments, string directory) {
        var owner = new TermBenchProcess();
        ProcessInfo info = new ProcessInfo();
        bool assigned = false;
        bool success = false;
        try {
            owner.job = CreateJobObject(IntPtr.Zero, null);
            if (owner.job == IntPtr.Zero) throw Error("CreateJobObject");
            var limits = new Limits { flags = 0x2000 }; // Kill descendants even if the runner is terminated.
            if (!SetInformationJobObject(owner.job, 9, ref limits, Marshal.SizeOf(limits)))
                throw Error("SetInformationJobObject");
            var startup = new Startup { cb = (uint)Marshal.SizeOf(typeof(Startup)), flags = 1, show = 0 };
            // Suspension closes the child-spawn race before job ownership is established.
            if (!CreateProcess(executable, new StringBuilder("\"" + executable + "\" " + arguments),
                IntPtr.Zero, IntPtr.Zero, false, 0x08000004, IntPtr.Zero, directory, ref startup, out info))
                throw Error("CreateProcess");
            owner.process = info.process;
            owner.Id = info.id;
            if (!AssignProcessToJobObject(owner.job, info.process)) throw Error("AssignProcessToJobObject");
            assigned = true;
            if (ResumeThread(info.thread) == 0xffffffff) throw Error("ResumeThread");
            if (!CloseHandle(info.thread)) throw Error("CloseHandle(thread)");
            info.thread = IntPtr.Zero;
            success = true;
            return owner;
        } catch {
            if (owner.process != IntPtr.Zero && !assigned) {
                if (!TerminateProcess(owner.process, 1)) throw Error("TerminateProcess after failed assignment");
                if (WaitForSingleObject(owner.process, 5000) != 0) throw new Exception("Startup cleanup timed out");
            }
            throw;
        } finally {
            try {
                if (info.thread != IntPtr.Zero && !CloseHandle(info.thread)) throw Error("CloseHandle(thread)");
            } finally {
                if (!success) owner.Dispose();
            }
        }
    }
    public void Dispose() {
        try {
            if (job != IntPtr.Zero) {
                if (!TerminateJobObject(job, 1)) throw Error("TerminateJobObject");
                var timer = System.Diagnostics.Stopwatch.StartNew();
                while (true) {
                    Accounting info;
                    if (!QueryInformationJobObject(job, 1, out info, Marshal.SizeOf(typeof(Accounting)), IntPtr.Zero))
                        throw Error("QueryInformationJobObject");
                    if (info.activeProcesses == 0) break;
                    if (timer.ElapsedMilliseconds >= 5000) throw new Exception("Owned process cleanup timed out");
                    System.Threading.Thread.Sleep(20);
                }
            }
        } finally {
            try {
                if (job != IntPtr.Zero && !CloseHandle(job)) throw Error("CloseHandle(job)");
            } finally {
                job = IntPtr.Zero;
                if (process != IntPtr.Zero && !CloseHandle(process)) throw Error("CloseHandle(process)");
                process = IntPtr.Zero;
            }
        }
        GC.SuppressFinalize(this);
    }
    ~TermBenchProcess() {
        if (job != IntPtr.Zero) CloseHandle(job);
        if (process != IntPtr.Zero) CloseHandle(process);
    }
}

public sealed class TermBenchDisplay {
    public bool Valid;
    public string Detail;
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] struct Point { public int x, y; }
    delegate bool EnumWindow(IntPtr window, IntPtr data);
    [DllImport("user32.dll", SetLastError = true)] static extern bool EnumWindows(EnumWindow callback, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll", SetLastError = true)] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr GetThreadDesktop(uint thread);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder text, uint size, out uint needed);
    [DllImport("user32.dll", SetLastError = true)] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, uint attribute, out uint value, uint size);

    static Exception Error(string call) {
        int code = Marshal.GetLastWin32Error();
        return new Win32Exception(code, call + " Win32=" + code);
    }
    static string DesktopName(IntPtr desktop) {
        if (desktop == IntPtr.Zero) throw Error("Open/GetThreadDesktop");
        var name = new StringBuilder(256);
        uint needed;
        if (!GetUserObjectInformation(desktop, 2, name, 512, out needed))
            throw Error("GetUserObjectInformation");
        return name.ToString();
    }
    public static TermBenchDisplay Probe(uint own) {
        IntPtr window = IntPtr.Zero;
        if (!EnumWindows(delegate(IntPtr candidate, IntPtr data) {
            uint pid;
            GetWindowThreadProcessId(candidate, out pid);
            if (pid == own && IsWindowVisible(candidate) && GetAncestor(candidate, 2) == candidate)
                window = candidate;
            return true;
        }, IntPtr.Zero)) throw Error("EnumWindows");
        if (window == IntPtr.Zero) return new TermBenchDisplay { Detail = "No visible owned top-level window" };
        IntPtr desktop = OpenInputDesktop(0, false, 1);
        string input;
        try { input = DesktopName(desktop); }
        finally {
            if (desktop != IntPtr.Zero && !CloseDesktop(desktop))
                throw Error("CloseDesktop");
        }
        uint pidAtWindow;
        uint thread = GetWindowThreadProcessId(window, out pidAtWindow);
        string target = DesktopName(GetThreadDesktop(thread));
        Rect rect;
        if (!GetWindowRect(window, out rect)) throw Error("GetWindowRect");
        uint cloaked;
        int result = DwmGetWindowAttribute(window, 14, out cloaked, 4);
        if (result < 0) throw new Exception("DwmGetWindowAttribute HRESULT=" + result);
        bool visible = IsWindowVisible(window), iconic = IsIconic(window);
        IntPtr monitor = MonitorFromWindow(window, 0);
        int hits = 0;
        foreach (int x in new int[] { 25, 50, 75 }) foreach (int y in new int[] { 25, 50, 75 }) {
            IntPtr hit = WindowFromPoint(new Point {
                x = rect.left + (rect.right - rect.left) * x / 100,
                y = rect.top + (rect.bottom - rect.top) * y / 100 });
            uint pid;
            GetWindowThreadProcessId(hit, out pid);
            if (pid == own && GetAncestor(hit, 2) == window) hits++;
        }
        uint foreground;
        GetWindowThreadProcessId(GetForegroundWindow(), out foreground);
        return new TermBenchDisplay {
            Valid = input == "Default" && target == input && pidAtWindow == own && visible && !iconic &&
                cloaked == 0 && monitor != IntPtr.Zero && rect.right > rect.left && rect.bottom > rect.top && hits == 9,
            Detail = "desktop=" + input + " targetDesktop=" + target + " own=" + own + " hwnd=" + window +
                " foreground=" + foreground + " monitor=" + monitor +
                " visible=" + visible + " iconic=" + iconic + " cloaked=" + cloaked +
                " hits=" + hits + "/9 rect=" + rect.left + "," + rect.top + "," +
                (rect.right - rect.left) + "," + (rect.bottom - rect.top)
        };
    }
}
