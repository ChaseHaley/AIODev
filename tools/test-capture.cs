using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

// Observe the standard runner; assertions, memory tracking and signal handling stay in Odin.
public sealed class AioTestCapture : IDisposable
{
    public sealed class Timing
    {
        public string Test { get; set; }
        public string State { get; set; }
        public double ObservedMilliseconds { get; set; }
    }
    public sealed class Fixture
    {
        public string Name { get; set; }
        public string Phase { get; set; }
        public double Milliseconds { get; set; }
        public int Windows { get; set; }
        public int Sessions { get; set; }
    }
    private readonly object gate = new object();
    private readonly StreamWriter log;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly Dictionary<string, double> started = new Dictionary<string, double>();
    private readonly List<Timing> tests = new List<Timing>();
    private readonly List<Fixture> fixtures = new List<Fixture>();
    private readonly ManualResetEventSlim stdoutDone = new ManualResetEventSlim();
    private readonly ManualResetEventSlim stderrDone = new ManualResetEventSlim();
    private bool disposed;
    private static readonly Regex state = new Regex(@"Test #\d+ (\S+) changed state to (Running|Successful|Failed)\.");
    private static readonly Regex fixture = new Regex(@"\[AIO-FIXTURE\] (\S+) (setup|cleanup) ([\d.]+) (\d+) (\d+)");

    public AioTestCapture(string path)
    {
        log = new StreamWriter(path, false, new UTF8Encoding(false)) { AutoFlush = true };
    }
    public Process Start(string executable, string arguments, string directory)
    {
        var process = new Process();
        process.StartInfo = new ProcessStartInfo(executable, arguments) {
            WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        process.OutputDataReceived += (sender, args) => Receive(args, stdoutDone);
        process.ErrorDataReceived += (sender, args) => Receive(args, stderrDone);
        try {
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            return process;
        } catch { process.Dispose(); throw; }
    }
    private void Receive(DataReceivedEventArgs args, ManualResetEventSlim done)
    {
        lock (gate) {
            if (disposed) return;
            if (args.Data == null) { done.Set(); return; }
            double now = clock.Elapsed.TotalMilliseconds;
            log.WriteLine(args.Data);
            var match = state.Match(args.Data);
            if (match.Success) {
                string name = match.Groups[1].Value;
                string result = match.Groups[2].Value;
                if (result == "Running") started[name] = now;
                else {
                    double start;
                    if (started.TryGetValue(name, out start)) {
                        tests.Add(new Timing { Test = name, State = result, ObservedMilliseconds = now - start });
                        started.Remove(name);
                    }
                }
            }
            match = fixture.Match(args.Data);
            if (match.Success) fixtures.Add(new Fixture {
                Name = match.Groups[1].Value, Phase = match.Groups[2].Value,
                Milliseconds = double.Parse(match.Groups[3].Value, CultureInfo.InvariantCulture),
                Windows = int.Parse(match.Groups[4].Value), Sessions = int.Parse(match.Groups[5].Value)
            });
        }
    }
    public Timing[] Tests { get { lock (gate) { return tests.ToArray(); } } }
    public Fixture[] Fixtures { get { lock (gate) { return fixtures.ToArray(); } } }
    public bool WaitForOutput(int milliseconds)
    {
        var wait = Stopwatch.StartNew();
        return stdoutDone.Wait(milliseconds) &&
            stderrDone.Wait(Math.Max(0, milliseconds - (int)wait.ElapsedMilliseconds));
    }
    public void Dispose()
    {
        lock (gate) {
            disposed = true;
            log.Dispose();
            stdoutDone.Dispose();
            stderrDone.Dispose();
        }
    }
}
