using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace Tqr
{
    // The only object accepted by the preview/copy/save layer. Text is immutable
    // and can only be constructed by the whitelist projection below, not raw logs.
    public sealed class SupportReport
    {
        public string Text { get; private set; }
        private SupportReport(string text) { Text = text; }
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        private const int InputLimit = 65536, OutputLimit = 16384;
        private static readonly string[] ProcessStates = { "Running", "Stopped", "Missing", "Not installed", "Unknown", "Unavailable" };
        private static readonly string[] ProbeStates = { "Reachable", "Unreachable", "Unknown", "Timed out", "Not supported", "Not confirmed", "Incomplete" };
        private static JavaScriptSerializer Json() { return new JavaScriptSerializer { MaxJsonLength = InputLimit, RecursionLimit = 10 }; }
        private static Dictionary<string, object> Map(object value) { return value as Dictionary<string, object> ?? new Dictionary<string, object>(); }
        private static object Get(Dictionary<string, object> map, string key) { object value; return map.TryGetValue(key, out value) ? value : null; }
        private static string Str(object value) { string s = value as string; return s != null && s.Length <= 256 ? s : ""; }
        private static string Choice(object value, params string[] allowed)
        {
            string s = Str(value);
            foreach (string item in allowed) if (String.Equals(s, item, StringComparison.OrdinalIgnoreCase)) return item;
            return "Unknown";
        }
        private static double Number(object value, double limit)
        {
            if (!(value is int || value is long || value is decimal || value is double)) return Double.NaN;
            double n = Convert.ToDouble(value, CultureInfo.InvariantCulture);
            return !Double.IsNaN(n) && !Double.IsInfinity(n) && n >= 0 && n <= limit ? n : Double.NaN;
        }
        private static string NumberText(object value, double limit)
        {
            double n = Number(value, limit);
            return Double.IsNaN(n) ? "Unknown" : Math.Round(n, 1).ToString(CultureInfo.InvariantCulture);
        }
        private static string Version(object value, bool product)
        {
            string s = Str(value);
            string pattern = product ? @"\A\d{1,3}\.\d{1,3}\.\d{1,3}(?:(?:-phase\d{1,3}\.\d{1,3}\.\d{1,3})|(?:-rc\.\d{1,3}))?\z" : @"\A\d{1,3}\.\d{1,3}\.\d{1,3}\z";
            return Regex.IsMatch(s, pattern, RegexOptions.CultureInvariant) ? s : "Unknown";
        }
        private static bool Stamp(object value, DateTime now, out DateTime stamp)
        {
            return DateTime.TryParseExact(Str(value), "o", CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out stamp)
                && stamp.Kind == DateTimeKind.Utc && stamp <= now.AddSeconds(5) && stamp.Year >= 2020;
        }
        private static string At(DateTime stamp) { return stamp.ToString("yyyy-MM-dd HH:mm:ss 'UTC'", CultureInfo.InvariantCulture); }
        private static string PathKind(object value)
        {
            string s = Str(value);
            if (s.Equals("Direct", StringComparison.OrdinalIgnoreCase)) return "Direct";
            if (s.Equals("Peer relay", StringComparison.OrdinalIgnoreCase)) return "Peer relay";
            if (Regex.IsMatch(s, @"\ARelay(?:\s*[/\u00b7-]\s*[A-Za-z0-9_-]{1,24})?\z", RegexOptions.IgnoreCase)) return "Relay";
            return "Unknown"; // The region/endpoint is intentionally never emitted.
        }
        private static string VpnLabel(object value)
        {
            string s = Str(value);
            string[] allowed = { "Proton VPN", "NordVPN", "Mullvad", "ExpressVPN", "Surfshark",
                "Private Internet Access", "Windscribe", "IVPN", "TunnelBear", "CyberGhost",
                "Cloudflare WARP", "Mozilla VPN", "hide.me", "PureVPN", "Hotspot Shield",
                "Cisco Secure Client", "GlobalProtect", "FortiClient VPN", "Ivanti Secure Access",
                "OpenVPN", "WireGuard", "VPN tunnel", "Multiple VPNs" };
            foreach (string item in allowed) if (String.Equals(s, item, StringComparison.Ordinal)) return item;
            return "VPN tunnel";
        }
        private static string VpnSummary(object stateValue, object labelValue)
        {
            string state = Choice(stateValue, "Detected", "NotDetected", "Unknown");
            if (state == "Detected") return "Active - " + VpnLabel(labelValue);
            if (state == "NotDetected") return "Not detected";
            return "Unavailable";
        }
        private static string Latency(object value)
        {
            string s = Str(value); double n;
            if (!Regex.IsMatch(s, @"\A\d{1,6}(?:\.\d{1,3})?\s*ms\z", RegexOptions.CultureInvariant)) return "Unknown";
            if (!Double.TryParse(s.Substring(0, s.Length - 2).Trim(), NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out n) || n > 600000) return "Unknown";
            return Math.Round(n, 1).ToString(CultureInfo.InvariantCulture) + " ms";
        }
        private static void Line(StringBuilder b, string name, string value) { b.Append(name).Append(": ").Append(value).Append("\r\n"); }
        private static bool True(object value) { return value is bool && (bool)value; }
        private static bool Snapshot(StringBuilder b, Dictionary<string, object> data, object requestedState, DateTime now)
        {
            string state = Choice(requestedState, "completed", "checking", "stale", "not_run", "incomplete");
            if (state == "checking") { Line(b, "State", "Check in progress; no completed result included"); return false; }
            if (state == "not_run") { Line(b, "State", "Not checked in this app session"); return false; }
            if (state == "incomplete") { Line(b, "State", "Inspection incomplete; no completed result included"); return false; }
            DateTime stamp;
            if ((state != "completed" && state != "stale") || !True(Get(data, "done")) || !Stamp(Get(data, "updatedUtc"), now, out stamp))
            { Line(b, "State", "No verified observation available"); return false; }
            Line(b, "State", state == "stale" || (now - stamp).TotalMinutes > 30 ? "Historical observation - run a fresh check" : "Completed observation (not continuous monitoring)");
            Line(b, "Observed", At(stamp));
            return true;
        }
        public static SupportReport Build(string sourceJson, bool includeHistory, DateTime nowUtc)
        {
            if (nowUtc.Kind != DateTimeKind.Utc || String.IsNullOrWhiteSpace(sourceJson) || sourceJson.Length > InputLimit)
                throw new InvalidDataException("Support snapshot unavailable.");
            Dictionary<string, object> root;
            try { root = Json().Deserialize<Dictionary<string, object>>(sourceJson); }
            catch { throw new InvalidDataException("Support snapshot unavailable."); }
            if (root == null) throw new InvalidDataException("Support snapshot unavailable.");
            DateTime now = nowUtc;
            StringBuilder b = new StringBuilder();
            b.Append("Tailscale Quick Repair - Support report\r\nReport format: 1\r\n");
            Line(b, "Created", At(now));
            b.Append("Privacy: names, addresses, paths, tokens and raw logs are excluded.\r\nScope: observed results only. Export runs no checks and uploads nothing.\r\n\r\n");
            Line(b, "Quick Repair version", Version(Get(root, "appVersion"), true));
            Line(b, "Tailscale version", Version(Get(root, "tailscaleVersion"), false));
            Line(b, "VPN context", VpnSummary(Get(root, "vpnState"), Get(root, "vpnLabel")));
            b.Append("\r\nCONNECTION CHECK\r\n");
            var main = Map(Get(root, "main"));
            if (Snapshot(b, main, Get(root, "mainState"), now))
            {
                Line(b, "Result category", Choice(Get(main, "mode"), "success", "warning", "error", "attention", "maintenance"));
                Line(b, "Desktop client", Choice(Get(main, "client"), ProcessStates));
                Line(b, "Windows service", Choice(Get(main, "service"), ProcessStates));
                Line(b, "Backend", Choice(Get(main, "backend"), ProcessStates));
                Line(b, "Remote status", Choice(Get(main, "peerReachable"), ProbeStates));
                Line(b, "Path", PathKind(Get(main, "route")));
                Line(b, "Latency", Latency(Get(main, "latency")));
                object repaired = Get(main, "repairPerformed");
                Line(b, "Repair actions reported", repaired is bool ? ((bool)repaired ? "Yes" : "No") : "Unknown");
            }
            b.Append("\r\nAPP INTEGRITY\r\n");
            var guardian = Map(Get(root, "guardian"));
            Line(b, "Result", Choice(Get(guardian, "state"), "Healthy", "Needs attention", "Check incomplete", "Checking", "Waiting", "Not checked"));
            DateTime checkedAt;
            if (Stamp(Get(guardian, "checkedUtc"), now, out checkedAt)) Line(b, "Observed", At(checkedAt));
            string gs = Str(Get(guardian, "state"));
            if (gs == "Healthy" || gs == "Needs attention")
            {
                Line(b, "Verified app files", NumberText(Get(guardian, "verifiedFiles"), 100));
                Line(b, "Issue count", NumberText(Get(guardian, "issues"), 100));
                Line(b, "Known-good baseline", Choice(Get(guardian, "baseline"), "Established", "Confirmed", "Not confirmed"));
            }
            b.Append("\r\nOPTIONAL DIAGNOSTICS\r\n");
            var diag = Map(Get(root, "diagnostics"));
            if (Snapshot(b, diag, Get(root, "diagnosticState"), now))
            {
                Line(b, "Network inspection", Choice(Get(diag, "netcheckStatus"), "Complete", "Incomplete", "Timed out"));
                foreach (string field in new[] { "udp", "ipv4", "ipv6" }) Line(b, field.ToUpperInvariant(), Choice(Get(diag, field), "Available", "Unavailable", "Unknown"));
                Line(b, "Path", PathKind(Get(diag, "path")));
                Line(b, "Latency", Latency(Get(diag, "latency")));
                Line(b, "Discovery", Choice(Get(diag, "disco"), ProbeStates));
                Line(b, "Tunnel", Choice(Get(diag, "tsmp"), ProbeStates));
                Line(b, "ICMP", Choice(Get(diag, "icmp"), ProbeStates));
                Line(b, "Peer API", Choice(Get(diag, "peerApi"), ProbeStates));
                Line(b, "NAT mapping", Choice(Get(diag, "mapping"), "Stable mapping", "Varies by destination", "Unknown"));
                var protocols = new List<string>();
                foreach (string p in new[] { "UPnP", "NAT-PMP", "PCP" })
                    if (Regex.IsMatch(Str(Get(diag, "portMapping")), @"\b" + p + @"\b", RegexOptions.IgnoreCase)) protocols.Add(p);
                Line(b, "Port mapping", protocols.Count == 0 ? "None confirmed" : String.Join(", ", protocols.ToArray()));
                Line(b, "Duration seconds", NumberText(Get(diag, "durationSeconds"), 300));
                b.Append("Separate point-in-time probes; not a bandwidth or RDP service test.\r\n");
            }
            b.Append("\r\nRECENT ACTIVITY\r\n");
            if (!includeHistory) b.Append("Not included.\r\n");
            else AddHistory(b, Map(Get(root, "history")), now);
            b.Append("\r\nReview this snapshot before sharing. Versions, timings and health results remain visible.\r\n");
            string text = b.ToString();
            if (text.Length > OutputLimit) throw new InvalidDataException("Support snapshot too large.");
            return new SupportReport(text);
        }
        private static void AddHistory(StringBuilder b, Dictionary<string, object> history, DateTime now)
        {
            var entries = Get(history, "entries") as IEnumerable;
            if (!(Get(history, "schema") is int) || (int)Get(history, "schema") != 1 || entries == null || entries is string)
            { b.Append("History unavailable or not yet recorded.\r\n"); return; }
            List<HistoryEntry> safe = new List<HistoryEntry>(); int examined = 0;
            foreach (object item in entries)
            {
                if (++examined > 40) { b.Append("History unavailable; entry limit exceeded.\r\n"); return; }
                var entry = Map(item); DateTime at;
                if (!Stamp(Get(entry, "utc"), now, out at) || at < now.AddDays(-30)) continue;
                string code = Str(Get(entry, "code"));
                int before = -1, after = -1;
                if (code == "latency_up" || code == "latency_down")
                {
                    double a = Number(Get(entry, "before"), 600000), z = Number(Get(entry, "after"), 600000);
                    if (Double.IsNaN(a) || Double.IsNaN(z)) continue;
                    before = (int)Math.Round(a); after = (int)Math.Round(z);
                }
                HistoryEntry h = new HistoryEntry { code = code, before = before, after = after, utc = at.ToString("o") };
                if (LocalHistory.Describe(h).Length > 0) safe.Add(h);
            }
            safe.Sort(delegate(HistoryEntry a, HistoryEntry z) { return StringComparer.Ordinal.Compare(z.utc, a.utc); });
            b.Append("Up to 10 recorded events from the last 30 days; newest first.\r\n");
            if (safe.Count == 0) b.Append("No eligible recorded events.\r\n");
            for (int i = 0; i < safe.Count && i < 10; i++)
            {
                DateTime at = DateTime.ParseExact(safe[i].utc, "o", CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
                b.Append(At(at)).Append(" - ").Append(LocalHistory.Describe(safe[i])).Append("\r\n");
            }
        }
        // Reads only the existing typed history file, never enumerates folders or
        // harvests logs. Export does not create a history lock or rewrite history.
        public static string ReadHistory(string directory)
        {
            try
            {
                string path = Path.Combine(Path.GetFullPath(directory), "health-history.json");
                RefuseReparseAncestors(path);
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (stream.Length > 32768) return "{}";
                    byte[] data = new byte[32769]; int total = 0, got;
                    while (total < data.Length && (got = stream.Read(data, total, data.Length - total)) > 0) total += got;
                    return total <= 32768 ? Utf8.GetString(data, 0, total) : "{}";
                }
            }
            catch { return "{}"; }
        }
        private static void RefuseReparseAncestors(string path)
        {
            for (string p = path; !String.IsNullOrEmpty(p); p = Path.GetDirectoryName(p))
                if ((File.Exists(p) || Directory.Exists(p)) && (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Choose an ordinary local folder.");
        }
        // New files only: an accidental filename collision cannot destroy an
        // existing report or another document. The destination is explicitly chosen.
        public void SaveNew(string destination)
        {
            if (String.IsNullOrWhiteSpace(destination) || !Path.IsPathRooted(destination)) throw new IOException("Choose a local text file.");
            string path = Path.GetFullPath(destination);
            if (path.StartsWith(@"\\", StringComparison.Ordinal) || path.IndexOf(':', 2) >= 0 ||
                !String.Equals(Path.GetExtension(path), ".txt", StringComparison.OrdinalIgnoreCase)) throw new IOException("Choose a local text file.");
            RefuseReparseAncestors(path);
            string directory = Path.GetDirectoryName(path);
            if (!Directory.Exists(directory) || File.Exists(path) || Directory.Exists(path)) throw new IOException("Choose a new filename.");
            string temp = Path.Combine(directory, ".tqr-export-" + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                byte[] data = Utf8.GetBytes(Text);
                using (FileStream stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                { stream.Write(data, 0, data.Length); stream.Flush(true); }
                RefuseReparseAncestors(path);
                File.Move(temp, path); // Fails, without replacement, if a destination appears meanwhile.
            }
            finally { if (File.Exists(temp)) File.Delete(temp); }
        }
    }
}
