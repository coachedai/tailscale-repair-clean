using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;

namespace Tqr
{
    public sealed class NotificationResult
    {
        public string Status = "suppressed";
        public bool Enabled;
        public string Title = "";
        public string Body = "";
        public bool Warning;
    }

    // Decision + tiny local policy store. No network, timers, repair or process control.
    // A prepared decision is an ATTEMPT, never proof Windows displayed a banner.
    public sealed class SmartNotifications
    {
        private readonly string root;
        private DateTime notBefore;
        private bool sessionDisabled;
        private readonly Dictionary<string, DateTime> seen = new Dictionary<string, DateTime>();
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
        private sealed class Attempt { public string code; public string eventUtc; public string requestedUtc; }
        private sealed class State
        {
            public int schema = 1;
            public bool enabled = false;
            public List<Attempt> attempts = new List<Attempt>();
        }
        public SmartNotifications(string directory, DateTime startedUtc)
        {
            root = Path.GetFullPath(directory);
            notBefore = startedUtc.ToUniversalTime();
        }
        private static JavaScriptSerializer Json()
        { return new JavaScriptSerializer { MaxJsonLength = 16384, RecursionLimit = 8 }; }
        public static bool ParseStamp(string value, out DateTime stamp)
        {
            return DateTime.TryParseExact(value, "o", CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out stamp) && stamp.Kind == DateTimeKind.Utc;
        }
        private static DateTime Stamp(string value)
        {
            DateTime stamp;
            if (!ParseStamp(value, out stamp)) throw new InvalidDataException("Invalid policy timestamp.");
            return stamp;
        }
        private static void RefuseReparse(string path)
        {
            if ((File.Exists(path) || Directory.Exists(path)) &&
                (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Notification state cannot use a reparse point.");
        }
        private FileStream Enter()
        {
            RefuseReparse(root);
            Directory.CreateDirectory(root);
            RefuseReparse(root);
            string gate = Path.Combine(root, "notification-policy.gate");
            RefuseReparse(gate);
            return new FileStream(gate, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        }
        private State Read()
        {
            string path = Path.Combine(root, "notification-policy.json");
            RefuseReparse(path);
            if (!File.Exists(path)) return new State();
            long length = new FileInfo(path).Length;
            if (length < 2 || length > 16384) throw new InvalidDataException("Invalid policy size.");
            var raw = Json().Deserialize<Dictionary<string, object>>(File.ReadAllText(path, Utf8));
            if (raw == null || raw.Count != 3 || !raw.ContainsKey("schema") ||
                !raw.ContainsKey("enabled") || !raw.ContainsKey("attempts") ||
                !(raw["enabled"] is bool) || !(raw["schema"] is int) || (int)raw["schema"] != 1)
                throw new InvalidDataException("Invalid notification settings.");
            IEnumerable items = raw["attempts"] as IEnumerable;
            if (items == null || raw["attempts"] is string) throw new InvalidDataException("Invalid notification history.");
            State state = new State { enabled = (bool)raw["enabled"] };
            foreach (object item in items)
            {
                var record = item as Dictionary<string, object>;
                if (record == null || record.Count != 3 || !record.ContainsKey("code") ||
                    !record.ContainsKey("eventUtc") || !record.ContainsKey("requestedUtc"))
                    throw new InvalidDataException("Invalid notification attempt.");
                string code = record["code"] as string;
                string utc = record["eventUtc"] as string;
                string requested = record["requestedUtc"] as string;
                if (Describe(code) == null) throw new InvalidDataException("Unsupported notification type.");
                Stamp(utc); Stamp(requested);
                state.attempts.Add(new Attempt { code = code, eventUtc = utc, requestedUtc = requested });
                if (state.attempts.Count > 64) throw new InvalidDataException("Too many notification attempts.");
            }
            return state;
        }
        private void Save(State state)
        {
            string path = Path.Combine(root, "notification-policy.json");
            string backup = Path.Combine(root, "notification-policy.previous.json");
            RefuseReparse(path); RefuseReparse(backup);
            string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                byte[] bytes = Utf8.GetBytes(Json().Serialize(state));
                if (bytes.Length > 16384) throw new InvalidDataException("Policy size limit.");
                using (FileStream stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                { stream.Write(bytes, 0, bytes.Length); stream.Flush(true); }
                if (File.Exists(path)) File.Replace(temp, path, backup);
                else File.Move(temp, path);
            }
            finally { if (File.Exists(temp)) File.Delete(temp); }
        }
        public NotificationResult Settings()
        {
            try { using (FileStream gate = Enter()) { State s = Read(); return new NotificationResult { Status = "ready", Enabled = s.enabled && !sessionDisabled }; } }
            catch { return new NotificationResult { Status = "unavailable" }; }
        }
        public NotificationResult SetEnabled(bool enabled, DateTime nowUtc)
        {
            // A user's OFF request takes effect in memory even if the file is locked.
            // A failed ON request must not remove an existing session mute.
            if (!enabled) sessionDisabled = true;
            try
            {
                using (FileStream gate = Enter())
                {
                    State s = Read();
                    s.enabled = enabled; Save(s);
                    sessionDisabled = !enabled;
                    notBefore = nowUtc.ToUniversalTime(); seen.Clear();
                    return new NotificationResult { Status = "ready", Enabled = enabled };
                }
            }
            catch { return new NotificationResult { Status = "unavailable" }; }
        }
        public NotificationResult Prepare(string code, string eventUtc, DateTime nowUtc, bool inTray, bool shellReady)
        {
            NotificationResult prompt = Describe(code);
            DateTime stamp;
            DateTime now = nowUtc.ToUniversalTime();
            if (prompt == null || !ParseStamp(eventUtc, out stamp)) return new NotificationResult { Status = "invalid" };
            bool explicitTest = code == "test";
            if (stamp < now.AddMinutes(-10) || stamp > now.AddSeconds(5) || (!explicitTest && stamp < notBefore))
                return new NotificationResult { Status = "stale" };
            DateTime last;
            if (seen.TryGetValue(code, out last) && stamp <= last) return new NotificationResult { Status = "duplicate" };
            seen[code] = stamp;
            try
            {
                using (FileStream gate = Enter())
                {
                    State s = Read();
                    if (!s.enabled || sessionDisabled) return new NotificationResult { Status = "disabled" };
                    if ((!inTray && !explicitTest) || !shellReady) return new NotificationResult { Status = "suppressed", Enabled = true };
                    int recent = 0;
                    foreach (Attempt a in s.attempts)
                    {
                        DateTime attempted = Stamp(a.requestedUtc);
                        if (attempted > now.AddSeconds(5)) return new NotificationResult { Status = "clock_changed", Enabled = true };
                        if (a.code == code && Stamp(a.eventUtc) >= stamp) return new NotificationResult { Status = "duplicate", Enabled = true };
                        if (attempted > now.AddHours(-1)) recent++;
                        if (attempted > now.AddMinutes(-2) || (a.code == code && attempted > now.AddMinutes(-30)))
                            return new NotificationResult { Status = "rate_limited", Enabled = true };
                    }
                    if (recent >= 3) return new NotificationResult { Status = "rate_limited", Enabled = true };
                    s.attempts.RemoveAll(delegate(Attempt a) { return Stamp(a.requestedUtc) < now.AddHours(-24); });
                    while (s.attempts.Count >= 64) s.attempts.RemoveAt(0);
                    s.attempts.Add(new Attempt { code = code, eventUtc = stamp.ToString("o"), requestedUtc = now.ToString("o") });
                    Save(s);
                    prompt.Status = "prepared"; prompt.Enabled = true;
                    return prompt;
                }
            }
            catch { return new NotificationResult { Status = "unavailable" }; }
        }
        public static NotificationResult Describe(string code)
        {
            string title, body; bool warning = false;
            switch (code)
            {
                case "auto_recovered": title = "Local recovery confirmed"; body = "Local Tailscale is healthy after a background recovery attempt."; break;
                case "auto_attention": title = "Automatic repair needs attention"; body = "The background monitor reported a problem. Open Quick Repair to review it."; warning = true; break;
                case "peer_lost": title = "Remote check needs attention"; body = "A completed check could not reach the other machine. Open Quick Repair for the result."; warning = true; break;
                case "peer_recovered": title = "Remote machine reachable again"; body = "A new completed check confirmed the connection is reachable."; break;
                case "quality_attention": title = "Connection quality changed"; body = "Recent completed checks show sustained latency or repeated path changes. The connection may still be reachable."; warning = true; break;
                case "update_available": title = "Quick Repair update available"; body = "A verified update check found a newer release. Open Maintenance to review and install it."; break;
                case "update_installed": title = "Quick Repair updated"; body = "The updater reported success. Open Maintenance to check the new installation."; break;
                case "update_attention": title = "Quick Repair update needs attention"; body = "The updater reported a problem. Open Maintenance to review the result before retrying."; warning = true; break;
                case "integrity_attention": title = "Quick Repair integrity needs attention"; body = "An integrity check found an issue. Open Maintenance to review it."; warning = true; break;
                case "startup_maintenance": title = "Quick Repair needs maintenance"; body = "Passive startup health found a local Quick Repair installation issue. Open Maintenance to review it."; warning = true; break;
                case "startup_config_attention": title = "Quick Repair target needs attention"; body = "Passive startup health could not validate the local target configuration. Open Quick Repair to review it."; warning = true; break;
                case "startup_tailscale_missing": title = "Tailscale is unavailable"; body = "Passive startup health could not find the local Tailscale service. Open Quick Repair to review it."; warning = true; break;
                case "startup_service_disabled": title = "Tailscale service is disabled"; body = "Passive startup health found the Tailscale service disabled and left it unchanged."; warning = true; break;
                case "startup_sign_in": title = "Tailscale sign-in needed"; body = "Passive startup health found that Tailscale needs sign-in. Open Tailscale when ready."; warning = true; break;
                case "startup_approval": title = "Tailscale approval needed"; body = "Passive startup health found that this Tailscale device needs approval."; warning = true; break;
                case "startup_other_user": title = "Tailscale is active for another user"; body = "Passive startup health found Tailscale active under another Windows user and left it unchanged."; warning = true; break;
                case "test": title = "Quick Repair notification test"; body = "Notifications are enabled. Only meaningful events observed while the app is running can alert you."; break;
                default: return null;
            }
            return new NotificationResult { Title = title, Body = body, Warning = warning };
        }
        [DllImport("shell32.dll", PreserveSig = true)]
        private static extern int SHQueryUserNotificationState(out int state);
        public static bool ShellAllowsNotifications()
        {
            try { int state; return SHQueryUserNotificationState(out state) >= 0 && state == 5; }
            catch { return false; }
        }
    }
}
