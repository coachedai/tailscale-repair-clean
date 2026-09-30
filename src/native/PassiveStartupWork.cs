using System;
using System.Collections;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;

namespace Tqr
{
    public sealed class PassiveStartupSample
    {
        public PassiveStartupObservation Observation;
        public bool EngineRepairable;
    }

    // One observation per instance. Runspace creation, invocation and disposal
    // never run on the caller's dispatcher. Cancellation never waits for them.
    public sealed class PassiveStartupWork : IDisposable
    {
        private readonly object sync = new object();
        private readonly int timeoutMs;
        private readonly Stopwatch clock = new Stopwatch();
        private bool started, finished;
        private string state = "Pending";
        private PowerShell active;
        private Timer deadline;
        private PassiveStartupSample sample;

        public PassiveStartupWork(int timeoutMilliseconds)
        {
            if (timeoutMilliseconds < 100 || timeoutMilliseconds > 15000)
                throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            timeoutMs = timeoutMilliseconds;
        }

        public string State { get { ExpireIfNeeded(); lock (sync) { return state; } } }
        public bool IsFinished { get { lock (sync) { return finished; } } }

        public bool TryStart(string collectionScript, Hashtable parameters)
        {
            if (String.IsNullOrWhiteSpace(collectionScript) || collectionScript.Length > 65536 || parameters == null)
                return false;
            // Only immutable local inputs; never retain a UI object or script delegate.
            Hashtable inputs = new Hashtable();
            foreach (DictionaryEntry entry in parameters)
            {
                // Pipeline strings can carry a PSObject wrapper. Inspect only
                // its CLR base value; never convert arbitrary objects to text.
                PSObject wrapped = entry.Value as PSObject;
                object value = wrapped == null ? entry.Value : wrapped.BaseObject;
                if (!(entry.Key is string) || (!(value is string) && !(value is bool) && value != null))
                    return false;
                inputs.Add(entry.Key, value);
            }
            lock (sync)
            {
                if (started || state != "Pending") return false;
                started = true;
                clock.Start();
                try
                {
                    deadline = new Timer(delegate(object unused) { Stop("TimedOut"); }, null, timeoutMs, Timeout.Infinite);
                    Thread worker = new Thread(delegate() { Collect(collectionScript, inputs); });
                    worker.IsBackground = true;
                    worker.SetApartmentState(ApartmentState.STA);
                    worker.Name = "Quick Repair passive startup";
                    worker.Start();
                    return true;
                }
                catch
                {
                    state = "Failed"; finished = true;
                    if (deadline != null) { deadline.Dispose(); deadline = null; }
                    return false;
                }
            }
        }

        private static string Known(string value, params string[] allowed)
        { return Array.IndexOf(allowed, value) >= 0 ? value : "Unknown"; }

        private static string SafeVersion(string value)
        {
            if (String.IsNullOrEmpty(value) || value.Length > 80) return "";
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                if (!(Char.IsLetterOrDigit(c) || c == '.' || c == '-' || c == '_' || c == '+' || c == '~'))
                    return "";
            }
            return value;
        }

        private static string SafeTailscaleIp(string value)
        {
            IPAddress address;
            if (String.IsNullOrEmpty(value) || value.Length > 64 || !IPAddress.TryParse(value, out address))
                return "";
            byte[] bytes = address.GetAddressBytes();
            if (address.AddressFamily == AddressFamily.InterNetwork &&
                bytes.Length == 4 && bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127)
                return address.ToString();
            if (address.AddressFamily == AddressFamily.InterNetworkV6 &&
                bytes.Length == 16 && bytes[0] == 0xfd && bytes[1] == 0x7a &&
                bytes[2] == 0x11 && bytes[3] == 0x5c && bytes[4] == 0xa1 && bytes[5] == 0xe0)
                return address.ToString();
            return "";
        }

        private static PassiveStartupSample Copy(PassiveStartupSample value)
        {
            if (value == null || value.Observation == null) return null;
            PassiveStartupObservation o = value.Observation;
            return new PassiveStartupSample {
                EngineRepairable = value.EngineRepairable,
                Observation = new PassiveStartupObservation {
                    AppFilesReady = o.AppFilesReady, EngineReady = o.EngineReady,
                    Config = Known(o.Config, "Configured", "Missing", "Invalid", "Unknown"),
                    Service = Known(o.Service, "Missing", "Stopped", "Running", "Unknown"),
                    Startup = Known(o.Startup, "Automatic", "Manual", "Disabled", "Unknown"),
                    Client = Known(o.Client, "Running", "Closed", "Unknown"),
                    Backend = Known(o.Backend, "NoState", "InUseOtherUser", "NeedsLogin", "NeedsMachineAuth", "Stopped", "Starting", "Running", "Unknown"),
                    LocalIp = SafeTailscaleIp(o.LocalIp),
                    Version = SafeVersion(o.Version)
                }
            };
        }

        private void ExpireIfNeeded()
        { if (clock.IsRunning && clock.ElapsedMilliseconds >= timeoutMs) Stop("TimedOut"); }

        public PassiveStartupSample ReadSample()
        { ExpireIfNeeded(); lock (sync) { return state == "Completed" ? Copy(sample) : null; } }

        private void Collect(string script, Hashtable inputs)
        {
            try
            {
                using (Runspace runspace = RunspaceFactory.CreateRunspace())
                {
                    runspace.ApartmentState = ApartmentState.STA;
                    // Use the already-owned background STA thread. An internal
                    // runspace thread must not keep the native host alive.
                    runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                    runspace.Open();
                    using (PowerShell shell = PowerShell.Create())
                    {
                        shell.Runspace = runspace;
                        shell.AddScript(script).AddParameters(inputs);
                        shell.InvocationStateChanged += delegate(object sender, PSInvocationStateChangedEventArgs change) {
                            if (change.InvocationStateInfo.State != PSInvocationState.Running) return;
                            bool cancelled;
                            lock (sync) { cancelled = state != "Pending"; }
                            // Covers cancellation between setting active and
                            // entering Invoke, without holding sync while waiting.
                            if (cancelled) QueueStop(shell);
                        };
                        lock (sync)
                        {
                            if (state != "Pending") return;
                            active = shell;
                        }
                        Collection<PSObject> output = shell.Invoke();
                        lock (sync)
                        {
                            if (state != "Pending") return;
                            if (clock.ElapsedMilliseconds >= timeoutMs) { state = "TimedOut"; return; }
                            if (output != null && !shell.HadErrors && output.Count == 1)
                                sample = Copy(output[0].BaseObject as PassiveStartupSample);
                            state = sample == null ? "Failed" : "Completed";
                        }
                    }
                }
            }
            catch { lock (sync) { if (state == "Pending") state = "Failed"; } }
            finally
            {
                lock (sync)
                {
                    active = null;
                    if (deadline != null) { deadline.Dispose(); deadline = null; }
                    finished = true;
                }
            }
        }

        private void Stop(string reason)
        {
            PowerShell shell;
            lock (sync)
            {
                if (state == "Cancelled" || state == "TimedOut" || state == "Failed") return;
                // A completed but not yet presented sample can still be invalidated.
                state = reason; sample = null; shell = active;
                if (deadline != null) { deadline.Dispose(); deadline = null; }
                if (!started) finished = true;
            }
            if (shell != null) QueueStop(shell);
        }

        private static void QueueStop(PowerShell shell)
        {
            // Never wait on the caller/UI thread. Stop synchronously on a
            // worker so a sleeping owned pipeline is interrupted promptly;
            // asynchronous BeginStop can leave it alive until its deadline.
            ThreadPool.QueueUserWorkItem(delegate(object unused) {
                try { shell.Stop(); }
                catch { }
            });
        }

        public void Cancel() { Stop("Cancelled"); }
        public void Dispose() { Cancel(); }
    }
}