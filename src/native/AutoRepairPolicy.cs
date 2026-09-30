using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace Tqr
{
    // No peer, address, process launch, service change or notification belongs here.
    // RequestRepair is a persisted reservation, never proof of dispatch or recovery.
    public sealed class AutoHealth
    {
        public string Service = "Unknown", Startup = "Unknown";
        public string Client = "Unknown", Backend = "Unknown";
    }
    public sealed class AutoDecision
    {
        public string Action, Reason;
        public int CooldownMinutes;
        public AutoDecision(string action, string reason, int minutes)
        { Action = action; Reason = reason; CooldownMinutes = minutes; }
    }
    public sealed class AutoPolicyState
    {
        public int Schema = 1, Attempts, HealthySamples;
        public string Observed = "", Candidate = "", CandidateSince = "";
        public string LastAttempt = "", NextAllowed = "", IntentHold = "", HealthySince = "";
    }
    public static class AutoRepairPolicy
    {
        private static readonly string[] Reasons = { "", "service_stopped", "client_closed", "backend_starting", "backend_no_state" };
        private static readonly string[] Holds = { "", "disconnected", "sign_in", "approval", "other_user" };
        public static string Backend(string value)
        {
            return In(value, "NoState", "InUseOtherUser", "NeedsLogin", "NeedsMachineAuth", "Stopped", "Starting", "Running") ? value : "Unknown";
        }
        private static bool In(string value, params string[] choices) { return Array.IndexOf(choices, value) >= 0; }
        private static string Stamp(DateTime value) { return value.ToString("o", CultureInfo.InvariantCulture); }
        internal static DateTime Time(string value)
        {
            DateTime result;
            if (String.IsNullOrEmpty(value)) return DateTime.MinValue;
            if (!DateTime.TryParseExact(value, "o", CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out result) || result.Kind != DateTimeKind.Utc)
                throw new InvalidDataException("Invalid policy timestamp.");
            return result;
        }
        private static AutoDecision D(string action, string reason) { return new AutoDecision(action, reason, 0); }
        internal static void Validate(AutoPolicyState s)
        {
            if (s == null || s.Schema != 1 || s.Attempts < 0 || s.Attempts > 3 || s.HealthySamples < 0 || s.HealthySamples > 3 ||
                !In(s.Candidate, Reasons) || !In(s.IntentHold, Holds)) throw new InvalidDataException("Invalid policy state.");
            foreach (string stamp in new[] { s.Observed, s.CandidateSince, s.LastAttempt, s.NextAllowed, s.HealthySince }) Time(stamp);
            if ((s.Candidate == "") != (s.CandidateSince == "") || (s.HealthySamples == 0) != (s.HealthySince == "") ||
                (s.LastAttempt == "") != (s.NextAllowed == "") || (s.Attempts == 0) != (s.LastAttempt == ""))
                throw new InvalidDataException("Inconsistent policy state.");
            DateTime observed = Time(s.Observed), attempted = Time(s.LastAttempt), next = Time(s.NextAllowed);
            if (Time(s.CandidateSince) > observed || Time(s.HealthySince) > observed || attempted > observed ||
                (attempted != DateTime.MinValue && (next - attempted).TotalMinutes != new[] { 0, 15, 30, 60 }[s.Attempts]))
                throw new InvalidDataException("Inconsistent policy chronology.");
        }
        public static AutoDecision Evaluate(AutoPolicyState s, AutoHealth h, DateTime now, bool enabled, bool busy)
        {
            if (!enabled) return D("Disabled", "off");
            if (busy) return D("Wait", "operation_busy");
            try { Validate(s); } catch { return D("Attention", "state_unavailable"); }
            if (now.Kind != DateTimeKind.Utc || now < Time(s.Observed)) return D("Attention", "clock_changed");
            if (h == null) return D("Wait", "unconfirmed");
            DateTime prior = Time(s.Observed);
            bool fresh = now > prior;
            bool continuity = prior != DateTime.MinValue && (now - prior).TotalMinutes <= 10;
            s.Observed = Stamp(now);
            string backend = Backend(h.Backend);
            string intent = backend == "Stopped" ? "disconnected" : backend == "NeedsLogin" ? "sign_in" :
                backend == "NeedsMachineAuth" ? "approval" : backend == "InUseOtherUser" ? "other_user" : "";
            if (intent != "") s.IntentHold = intent;
            // A previously observed intentional/authentication hold survives service loss.
            // Only a later explicit Running backend observation can release that hold.
            else if (h.Service == "Running" && backend == "Running") s.IntentHold = "";
            bool healthy = h.Service == "Running" && h.Client == "Running" && backend == "Running" && h.Startup != "Disabled";
            if (healthy)
            {
                s.Candidate = s.CandidateSince = "";
                if (!continuity || s.HealthySince == "") { s.HealthySince = Stamp(now); s.HealthySamples = 1; }
                else if (fresh && (now - Time(s.HealthySince)).TotalMinutes >= 5 * s.HealthySamples) s.HealthySamples = Math.Min(3, s.HealthySamples + 1);
                if (s.HealthySamples >= 3 && (now - Time(s.HealthySince)).TotalMinutes >= 10)
                { s.Attempts = 0; s.LastAttempt = s.NextAllowed = ""; }
                return D("Healthy", "local_running");
            }
            s.HealthySince = ""; s.HealthySamples = 0;
            string attention = h.Service == "Missing" ? "installation_missing" : h.Startup == "Disabled" ? "service_disabled" : s.IntentHold;
            if (attention != "") { s.Candidate = s.CandidateSince = ""; return D("Attention", attention); }
            string reason = "";
            if (h.Service == "Stopped" && In(h.Startup, "Automatic", "Manual")) reason = "service_stopped";
            else if (h.Service == "Running")
            {
                if (backend == "Starting") reason = "backend_starting";
                else if (backend == "NoState") reason = "backend_no_state";
                else if (backend == "Running" && h.Client == "Closed") reason = "client_closed";
            }
            if (reason == "") { s.Candidate = s.CandidateSince = ""; return D("Wait", "unconfirmed"); }
            if (now < Time(s.NextAllowed))
                return new AutoDecision("Cooldown", "recent_attempt", (int)Math.Ceiling((Time(s.NextAllowed) - now).TotalMinutes));
            if (s.Attempts >= 3) return D("Attention", "retry_limit");
            if (!continuity || s.Candidate != reason || s.CandidateSince == "")
            { s.Candidate = reason; s.CandidateSince = Stamp(now); return D("Wait", "confirming_fault"); }
            int grace = reason.StartsWith("backend_", StringComparison.Ordinal) ? 60 : 30;
            if (!fresh || (now - Time(s.CandidateSince)).TotalSeconds < grace) return D("Wait", "confirming_fault");
            s.Attempts++;
            s.LastAttempt = Stamp(now);
            s.NextAllowed = Stamp(now.AddMinutes(new[] { 0, 15, 30, 60 }[s.Attempts]));
            s.Candidate = s.CandidateSince = "";
            return D("RequestRepair", reason);
        }
    }

    // One bounded policy file and predecessor. Corruption/lock failure never resets
    // the budget. The lock file is persistent: disposing closes its handle only.
    public static class AutoRepairPolicyStore
    {
        private const int Limit = 16384;
        private static JavaScriptSerializer Json() { return new JavaScriptSerializer { MaxJsonLength = Limit, RecursionLimit = 8 }; }
        private static readonly string[] Keys = { "Schema", "Attempts", "HealthySamples", "Observed", "Candidate", "CandidateSince", "LastAttempt", "NextAllowed", "IntentHold", "HealthySince" };
        private static void SafePath(string path)
        {
            string full = Path.GetFullPath(path);
            if (full.StartsWith(@"\\", StringComparison.Ordinal) || full.IndexOf(':', 2) >= 0) throw new IOException("Local path required.");
            string current = full;
            while (!String.IsNullOrEmpty(current))
            {
                try
                {
                    FileAttributes attributes = File.GetAttributes(current);
                    if ((attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("Reparse path refused.");
                }
                catch (FileNotFoundException) { }
                catch (DirectoryNotFoundException) { }
                current = Path.GetDirectoryName(current);
            }
        }
        private static string ReadBounded(string path)
        {
            SafePath(path);
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (stream.Length <= 0 || stream.Length > Limit) throw new InvalidDataException("Invalid policy size.");
                byte[] bytes = new byte[(int)stream.Length]; int offset = 0;
                while (offset < bytes.Length)
                { int n = stream.Read(bytes, offset, bytes.Length - offset); if (n == 0) throw new EndOfStreamException(); offset += n; }
                if (stream.ReadByte() != -1) throw new InvalidDataException("Policy changed during read.");
                string text = new UTF8Encoding(false, true).GetString(bytes);
                return text.TrimStart('\uFEFF');
            }
        }
        public static bool? ReadEnabled(string root)
        {
            try { return ReadSettingsPath(Path.Combine(root,"auto-repair.json")); }
            catch { return null; }
        }
        private static bool? ReadSettingsPath(string path)
        {
            try
            {
                SafePath(path);
                string text;
                try { text = ReadBounded(path); } catch (FileNotFoundException) { return false; }
                // Our settings contain only a boolean and an optional UTC timestamp.
                // Escaped property names cannot alias a duplicate literal name.
                if (text.IndexOf('\\') >= 0) return null;
                Dictionary<string, object> data = Json().DeserializeObject(text) as Dictionary<string, object>;
                object value;
                if (data == null || data.Count < 1 || data.Count > 2 ||
                    !data.TryGetValue("enabled", out value) || !(value is bool) ||
                    Regex.Matches(text, "\"enabled\"\\s*:").Count != 1) return null;
                foreach (string key in data.Keys)
                    if (key != "enabled" && key != "updatedUtc") return null;
                object updated;
                if (data.TryGetValue("updatedUtc", out updated))
                {
                    if (!(updated is string) || String.IsNullOrEmpty((string)updated) ||
                        Regex.Matches(text, "\"updatedUtc\"\\s*:").Count != 1) return null;
                    AutoRepairPolicy.Time((string)updated);
                }
                return (bool)value;
            }
            catch { return null; }
        }
        private static AutoPolicyState Load(string path)
        {
            string text = ReadBounded(path);
            // Every permitted string is a fixed code or a round-trip UTC stamp;
            // neither requires JSON escapes. Reject aliases before deserialization.
            if (text.IndexOf('\\') >= 0) throw new InvalidDataException("Noncanonical policy strings.");
            Dictionary<string, object> data = Json().DeserializeObject(text) as Dictionary<string, object>;
            if (data == null || data.Count != Keys.Length) throw new InvalidDataException("Unexpected policy fields.");
            foreach (string key in Keys)
            {
                object value;
                if (!data.TryGetValue(key, out value) || Regex.Matches(text, "\"" + key + "\"\\s*:").Count != 1)
                    throw new InvalidDataException("Missing or duplicate policy field.");
                bool numeric = key == "Schema" || key == "Attempts" || key == "HealthySamples";
                if (numeric ? !(value is int) : !(value is string)) throw new InvalidDataException("Wrong policy field type.");
            }
            AutoPolicyState state = Json().Deserialize<AutoPolicyState>(text);
            AutoRepairPolicy.Validate(state);
            return state;
        }
        private static void Save(string path, AutoPolicyState state)
        {
            AutoRepairPolicy.Validate(state);
            string previous = path + ".previous"; SafePath(path); SafePath(previous);
            byte[] bytes = new UTF8Encoding(false).GetBytes(Json().Serialize(state));
            if (bytes.Length > Limit) throw new InvalidDataException("Policy too large.");
            string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (FileStream stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                { stream.Write(bytes, 0, bytes.Length); stream.Flush(true); }
                if (File.Exists(path)) File.Replace(temp, path, previous);
                else File.Move(temp, path);
            }
            finally { if (File.Exists(temp)) File.Delete(temp); }
        }
        // Migration preserves the previous monitor's most recent reservation;
        // its legacy "repaired" label is not promoted to a confirmed recovery.
        public static void ImportLegacyAttempt(string root, string stamp, DateTime now)
        {
            if (String.IsNullOrEmpty(stamp)) return;
            DateTime attempted=AutoRepairPolicy.Time(stamp);
            if(now.Kind!=DateTimeKind.Utc || attempted>now) throw new InvalidDataException("clock_changed");
            string path=Path.Combine(root,"auto-repair-policy.json"),lockPath=Path.Combine(root,"auto-repair-policy.lock");
            SafePath(root);SafePath(path);SafePath(lockPath);
            using(FileStream lease=new FileStream(lockPath,FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None))
            {
                if(lease.Length!=0 || ReadEnabled(root)!=true) throw new InvalidDataException("settings_unavailable");
                try { Load(path);return; } catch(FileNotFoundException) { }
                SafePath(path+".previous");
                if(File.Exists(path+".previous") || Directory.Exists(path+".previous")) throw new InvalidDataException("state_unavailable");
                AutoPolicyState state=new AutoPolicyState();
                state.Observed=now.ToString("o",CultureInfo.InvariantCulture);
                state.Attempts=1;state.LastAttempt=stamp;state.NextAllowed=attempted.AddMinutes(15).ToString("o",CultureInfo.InvariantCulture);
                Save(path,state);
            }
        }

        public static bool SetEnabled(string root, bool enabled, DateTime now)
        {
            try
            {
                SafePath(root);
                if(now.Kind!=DateTimeKind.Utc || !Directory.Exists(root) || !ReadEnabled(root).HasValue) return false;
                string path=Path.Combine(root,"auto-repair.json"),lockPath=Path.Combine(root,"auto-repair-settings.lock");
                SafePath(path);SafePath(lockPath);
                using(FileStream lease=new FileStream(lockPath,FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None))
                {
                    if(lease.Length!=0 || !ReadEnabled(root).HasValue) return false;
                    string previous=path+".previous";SafePath(previous);
                    // Settings writes preserve existing malformed predecessor evidence.
                    if(!ReadSettingsPath(previous).HasValue) return false;
                    byte[] bytes=new UTF8Encoding(false).GetBytes(Json().Serialize(new Dictionary<string,object> {
                        {"enabled",enabled},{"updatedUtc",now.ToString("o",CultureInfo.InvariantCulture)} }));
                    string scratch=path+"."+Guid.NewGuid().ToString("N")+".tmp";
                    try
                    {
                        using(FileStream f=new FileStream(scratch,FileMode.CreateNew,FileAccess.Write,FileShare.None)) { f.Write(bytes,0,bytes.Length);f.Flush(true); }
                        if(File.Exists(path)) File.Replace(scratch,path,previous);else File.Move(scratch,path);
                    }
                    finally { if(File.Exists(scratch)) File.Delete(scratch); }
                    return true;
                }
            }
            catch { return false; }
        }

        public static AutoDecision Observe(string root, AutoHealth health, DateTime now, bool busy)
        {
            bool? enabled = ReadEnabled(root);
            if (!enabled.HasValue) return new AutoDecision("Attention", "settings_unavailable", 0);
            if (!enabled.Value) return new AutoDecision("Disabled", "off", 0);
            if (busy) return new AutoDecision("Wait", "operation_busy", 0);
            try
            {
                SafePath(root);
                if (!Directory.Exists(root)) throw new DirectoryNotFoundException();
                string path = Path.Combine(root, "auto-repair-policy.json");
                string lockPath = Path.Combine(root, "auto-repair-policy.lock");
                SafePath(lockPath);
                using (FileStream lease = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
                {
                    if (lease.Length != 0) throw new InvalidDataException("Unexpected lock contents.");
                    // Recheck the preference after taking the policy lease.
                    enabled = ReadEnabled(root);
                    if (!enabled.HasValue) throw new InvalidDataException("Settings unavailable.");
                    if (!enabled.Value) return new AutoDecision("Disabled", "off", 0);
                    AutoPolicyState state;
                    try { state = Load(path); }
                    catch (FileNotFoundException)
                    {
                        SafePath(path + ".previous");
                        if (File.Exists(path + ".previous") || Directory.Exists(path + ".previous")) throw new InvalidDataException("Primary policy missing.");
                        state = new AutoPolicyState();
                    }
                    if (File.Exists(path + ".previous") || Directory.Exists(path + ".previous")) Load(path + ".previous");
                    AutoDecision decision = AutoRepairPolicy.Evaluate(state, health, now, true, false);
                    if (decision.Reason == "clock_changed" || decision.Reason == "state_unavailable") return decision;
                    // Commit the reservation BEFORE the caller is allowed to dispatch.
                    // A crash or ambiguous dispatch consumes the slot, never retries it.
                    Save(path, state);
                    return decision;
                }
            }
            catch { return new AutoDecision("Attention", "state_unavailable", 0); }
        }
    }
}
