using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace Tqr
{
    public sealed class AutoBackendObservation
    {
        public string Backend = "Unknown", Status = "Unconfirmed";
        // Only validated self metadata from the fixed --peers=false response.
        // No hostname, tailnet, peer, auth URL or raw output is retained.
        public string LocalIp = "", Version = "";
        public int ExitCode = -1, DurationMs, RetainedBytes;
    }

    // A read-only collector, not an automatic repair worker. The integration layer
    // must select the installed CLI and recheck ownership/intent before mutation.
    public static class AutoRepairLocalStatus
    {
        private const int Limit = 65536;
        private sealed class Capture
        {
            internal readonly object Sync = new object();
            internal readonly MemoryStream Stdout = new MemoryStream();
            internal int Total, Retained;
            internal bool Overflow, ReadError, StdoutDone, StderrDone, HasStderr;
        }
        private static void Pump(Stream stream, Capture capture, bool output)
        {
            byte[] buffer = new byte[4096];
            try
            {
                int count;
                while ((count = stream.Read(buffer, 0, buffer.Length)) != 0)
                {
                    lock (capture.Sync)
                    {
                        int keep = Math.Min(count, Math.Max(0, Limit - capture.Total));
                        if (keep < count) capture.Overflow = true;
                        capture.Total = Math.Min(Limit, capture.Total + count);
                        if (output && keep != 0)
                        { capture.Stdout.Write(buffer, 0, keep); capture.Retained += keep; }
                        if (!output) capture.HasStderr = true;
                    }
                }
            }
            catch { lock (capture.Sync) { capture.ReadError = true; } }
            finally
            {
                lock (capture.Sync)
                { if (output) capture.StdoutDone = true; else capture.StderrDone = true; }
            }
        }
        private static bool DistinctTopLevelNames(string json)
        {
            // The full parser has already checked JSON syntax. Walk string tokens
            // so escaped quotes inside values cannot manufacture a property name.
            HashSet<string> names = new HashSet<string>(StringComparer.Ordinal);
            int depth = 0;
            for (int i = 0; i < json.Length; i++)
            {
                char c = json[i];
                if (c == '{' || c == '[') { depth++; continue; }
                if (c == '}' || c == ']') { depth--; continue; }
                if (c != '"') continue;
                int start = i++; bool escaped = false;
                while (i < json.Length)
                {
                    if (json[i] == '\\') { escaped = true; i += 2; continue; }
                    if (json[i] == '"') break;
                    i++;
                }
                if (i >= json.Length) return false;
                int next = i + 1;
                while (next < json.Length && Char.IsWhiteSpace(json[next])) next++;
                if (depth == 1 && next < json.Length && json[next] == ':')
                {
                    // Tailscale's fixed schema uses literal ASCII property names.
                    if (escaped || !names.Add(json.Substring(start + 1, i - start - 1))) return false;
                }
            }
            return true;
        }
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

        private static string FirstTailscaleIp(object raw)
        {
            IEnumerable values = raw as IEnumerable;
            if (values == null || raw is string) return "";
            string ipv6 = ""; int count = 0;
            foreach (object item in values)
            {
                if (++count > 8) return "";
                string candidate = item as string;
                if (candidate == null) continue;
                string safe = SafeTailscaleIp(candidate);
                if (String.IsNullOrEmpty(safe)) continue;
                IPAddress address;
                if (IPAddress.TryParse(safe, out address) && address.AddressFamily == AddressFamily.InterNetwork)
                    return safe;
                if (String.IsNullOrEmpty(ipv6)) ipv6 = safe;
            }
            return ipv6;
        }

        public static AutoBackendObservation Parse(string json, int exitCode, bool timedOut, bool incomplete)
        {
            AutoBackendObservation result = new AutoBackendObservation { ExitCode = exitCode };
            if (timedOut) { result.Status = "TimedOut"; return result; }
            if (incomplete) { result.Status = "Incomplete"; return result; }
            if (exitCode != 0) { result.Status = "CommandFailed"; return result; }
            if (String.IsNullOrEmpty(json) || json.Length > Limit) return result;
            try
            {
                JavaScriptSerializer parser = new JavaScriptSerializer { MaxJsonLength = Limit, RecursionLimit = 16 };
                Dictionary<string, object> data = parser.DeserializeObject(json) as Dictionary<string, object>;
                object value;
                if (data == null || !DistinctTopLevelNames(json) || !data.TryGetValue("BackendState", out value) || !(value is string)) return result;
                result.Backend = AutoRepairPolicy.Backend((string)value);
                object versionValue;
                if (data.TryGetValue("Version", out versionValue) && versionValue is string)
                    result.Version = SafeVersion((string)versionValue);
                object ipValue;
                if (data.TryGetValue("TailscaleIPs", out ipValue))
                    result.LocalIp = FirstTailscaleIp(ipValue);
                if (result.Backend != "Unknown") result.Status = "Complete";
            }
            catch { }
            return result;
        }
        public static AutoBackendObservation Read(string executable, int timeoutMs)
        {
            AutoBackendObservation result = new AutoBackendObservation();
            Stopwatch watch = Stopwatch.StartNew();
            Process process = new Process(); Capture capture = new Capture();
            Thread stdout = null, stderr = null; bool started = false, timedOut = false;
            try
            {
                if (timeoutMs < 100 || timeoutMs > 10000 || String.IsNullOrEmpty(executable) ||
                    !Path.IsPathRooted(executable) || executable.StartsWith(@"\\", StringComparison.Ordinal) ||
                    !String.Equals(Path.GetExtension(executable), ".exe", StringComparison.OrdinalIgnoreCase)) return result;
                // No target, shell, arbitrary command or fallback probe is accepted.
                process.StartInfo = new ProcessStartInfo(executable, "status --json --peers=false")
                {
                    UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
                    RedirectStandardOutput = true, RedirectStandardError = true
                };
                started = process.Start();
                if (!started) return result;
                Stream output = process.StandardOutput.BaseStream, error = process.StandardError.BaseStream;
                stdout = new Thread(delegate() { Pump(output, capture, true); });
                stderr = new Thread(delegate() { Pump(error, capture, false); });
                stdout.IsBackground = stderr.IsBackground = true;
                stdout.Start(); stderr.Start();
                while (!process.WaitForExit(20))
                {
                    lock (capture.Sync) { if (capture.Overflow || capture.ReadError) break; }
                    if (watch.ElapsedMilliseconds >= timeoutMs) { timedOut = true; break; }
                }
                if (!process.HasExited)
                {
                    process.Kill(); // Only the exact child created by this request.
                    if (!process.WaitForExit(1000)) { result.Status = "Incomplete"; return result; }
                }
                bool drainedOut = stdout.Join(500), drainedErr = stderr.Join(500);
                string json = ""; bool incomplete;
                lock (capture.Sync)
                {
                    incomplete = !drainedOut || !drainedErr || capture.ReadError || capture.Overflow || capture.HasStderr;
                    result.RetainedBytes = capture.Retained;
                    if (!incomplete && !timedOut) json = new UTF8Encoding(false, true).GetString(capture.Stdout.ToArray());
                }
                int retained = result.RetainedBytes;
                result = Parse(json, process.ExitCode, timedOut, incomplete);
                result.RetainedBytes = retained;
            }
            catch { result.Status = timedOut ? "TimedOut" : "Unconfirmed"; }
            finally
            {
                try { if (started && !process.HasExited) { process.Kill(); process.WaitForExit(1000); } } catch { }
                try { process.Dispose(); } catch { }
                if (stdout != null && stdout.IsAlive) stdout.Join(200);
                if (stderr != null && stderr.IsAlive) stderr.Join(200);
                // No raw stdout/stderr is returned, logged or written to disk.
                lock (capture.Sync) { result.RetainedBytes = capture.Retained; }
                result.DurationMs = (int)Math.Min(Int32.MaxValue, watch.ElapsedMilliseconds);
            }
            return result;
        }
    }
}