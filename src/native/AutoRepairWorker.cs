using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace Tqr
{
    // Only the OS boundary is replaceable in tests. No peer or arbitrary command input.
    public interface IAutoRepairMachine
    {
        DateTime UtcNow { get; }
        bool CanContinue { get; }
        bool CanMutate { get; }
        AutoHealth Observe();
        bool OpenClient(Action authorize);
        bool StartService(Action authorize);
        bool StopService(Action authorize);
        void Pause();
    }
    public sealed class AutoRepairResult
    {
        public int schema = 3, actionsAttempted, actionsCompleted, cooldownRemainingMinutes;
        public string runId = "", lastCheckedUtc = "", status = "waiting", reason = "unconfirmed", phase = "Observed";
        public string service = "Unknown", client = "Unknown", backend = "Unknown";
        public string lastRepairUtc = "", lastRepairReason = "";
        public bool recoveryConfirmed;
        public string reservedUtc = "", action1 = "", action2 = "", action3 = "";
        public string action1Utc = "", action2Utc = "", action3Utc = "";
    }
    public static class AutoRepairRecords
    {
        private static JavaScriptSerializer Json() { return new JavaScriptSerializer { MaxJsonLength = 8192, RecursionLimit = 8 }; }
        public static void CheckPath(string path)
        {
            if (String.IsNullOrEmpty(path) || !Path.IsPathRooted(path)) throw new IOException("Absolute local path required.");
            string full = Path.GetFullPath(path);
            if (full.StartsWith(@"\\", StringComparison.Ordinal) || full.IndexOf(':', 2) >= 0) throw new IOException("Local path required.");
            for (string p = full; !String.IsNullOrEmpty(p); p = Path.GetDirectoryName(p))
            {
                try { if ((File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0) throw new IOException("Reparse path refused."); }
                catch (FileNotFoundException) { }
                catch (DirectoryNotFoundException) { }
            }
        }
        private static Dictionary<string, object> Read(string path)
        {
            CheckPath(path);
            byte[] bytes;
            using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (f.Length < 2 || f.Length > 8192) throw new InvalidDataException("Invalid result size.");
                bytes = new byte[(int)f.Length]; int at = 0;
                while (at < bytes.Length) { int n = f.Read(bytes, at, bytes.Length-at); if (n == 0) throw new EndOfStreamException(); at += n; }
                if (f.ReadByte()!=-1) throw new InvalidDataException("Result changed during read.");
            }
            string text = new UTF8Encoding(false, true).GetString(bytes).TrimStart('\uFEFF');
            Dictionary<string, object> doc = Json().DeserializeObject(text) as Dictionary<string, object>;
            if (doc == null) throw new InvalidDataException("Invalid result.");
            if (doc.ContainsKey("schema"))
            {
                if (text.IndexOf('\\') >= 0) throw new InvalidDataException("Noncanonical result.");
                bool older = doc["schema"] is int && (int)doc["schema"] == 2;
                if (doc.Count != typeof(AutoRepairResult).GetFields().Length - (older ? 7 : 0)) throw new InvalidDataException("Unknown result fields.");
                foreach (System.Reflection.FieldInfo field in typeof(AutoRepairResult).GetFields())
                {
                    if (older && IsAuditField(field.Name)) continue;
                    object v;
                    if (!doc.TryGetValue(field.Name, out v) || v == null || v.GetType() != field.FieldType ||
                        Regex.Matches(text, "\"" + field.Name + "\"\\s*:").Count != 1) throw new InvalidDataException("Invalid result field.");
                }
                Validate(Json().Deserialize<AutoRepairResult>(text));
            }
            else
            {
                // Recognize the previous monitor solely for migration. Never copy
                // its free message into a new status, event or policy record.
                string[] old = { "lastCheckedUtc", "status", "message", "service", "client", "backend", "lastRepairUtc", "lastRepairReason", "cooldownRemainingMinutes" };
                if (doc.Count != old.Length) throw new InvalidDataException("Unknown legacy result.");
                foreach (string key in old)
                {
                    object v;
                    if (!doc.TryGetValue(key, out v) || (key == "cooldownRemainingMinutes" ? !(v is int) : !(v is string)) ||
                        Regex.Matches(text, "\"" + key + "\"\\s*:").Count != 1) throw new InvalidDataException("Invalid legacy result field.");
                }
                AutoRepairPolicy.Time((string)doc["lastCheckedUtc"]);
                AutoRepairPolicy.Time((string)doc["lastRepairUtc"]);
                if (Array.IndexOf(new[] { "disabled", "busy", "healthy", "cooldown", "repaired", "error", "manual" }, (string)doc["status"]) < 0)
                    throw new InvalidDataException("Unknown legacy status.");
            }
            return doc;
        }
        private static bool IsAuditField(string name)
        {
            return name == "reservedUtc" || name == "action1" || name == "action2" || name == "action3" ||
                name == "action1Utc" || name == "action2Utc" || name == "action3Utc";
        }
        private static bool OneOf(string v, params string[] choices) { return Array.IndexOf(choices, v) >= 0; }
        private static void Validate(AutoRepairResult r)
        {
            Guid id;
            if ((r.schema != 2 && r.schema != 3) || !Guid.TryParseExact(r.runId,"N",out id) || String.IsNullOrEmpty(r.lastCheckedUtc) ||
                r.actionsAttempted < 0 || r.actionsAttempted > 3 || r.actionsCompleted < 0 || r.actionsCompleted > r.actionsAttempted ||
                r.cooldownRemainingMinutes < 0 || r.cooldownRemainingMinutes > 60 ||
                !OneOf(r.status,"waiting","healthy","cooldown","manual","error","repairing","disabled","busy") ||
                !OneOf(r.phase,"Observed","Reserved","OpeningClient","StartingService","StoppingService","Verifying","Complete") ||
                !OneOf(r.service,"Running","Stopped","Missing","Unknown") || !OneOf(r.client,"Running","Closed","Unknown") ||
                AutoRepairPolicy.Backend(r.backend) != r.backend || !OneOf(r.reason,"unconfirmed","off","settings_unavailable","integration_unavailable","operation_busy","clock_changed","state_unavailable","installation_missing","service_disabled","disconnected","sign_in","approval","other_user","local_running","recent_attempt","retry_limit","confirming_fault","service_stopped","client_closed","backend_starting","backend_no_state","action_completed","action_unconfirmed","observation_changed","local_recovery","recovery_unconfirmed","ownership_changed","interrupted","state_or_action_unavailable"))
                throw new InvalidDataException("Invalid result vocabulary.");
            DateTime when = AutoRepairPolicy.Time(r.lastCheckedUtc), repair = AutoRepairPolicy.Time(r.lastRepairUtc);
            if (r.schema == 3)
            {
                DateTime reserved = AutoRepairPolicy.Time(r.reservedUtc), last = reserved;
                if ((r.actionsAttempted > 0 && reserved == DateTime.MinValue) || reserved > when)
                    throw new InvalidDataException("Missing reservation evidence.");
                string[] actions = { r.action1, r.action2, r.action3 };
                string[] stamps = { r.action1Utc, r.action2Utc, r.action3Utc };
                for (int i=0; i<3; i++)
                {
                    if (i >= r.actionsCompleted)
                    { if (actions[i] != "" || stamps[i] != "") throw new InvalidDataException("Unexpected action evidence."); continue; }
                    DateTime at = AutoRepairPolicy.Time(stamps[i]);
                    if (!OneOf(actions[i],"client_opened","service_started","service_stopped") || at == DateTime.MinValue || at < last || at > when)
                        throw new InvalidDataException("Invalid completed action evidence.");
                    last = at;
                }
            }
            if (r.recoveryConfirmed != (r.lastRepairUtc != "") ||
                (r.recoveryConfirmed && (r.status != "healthy" || r.phase!="Complete" || r.actionsCompleted == 0 || r.service != "Running" ||
                    r.client != "Running" || r.backend != "Running" || repair > when || r.lastRepairReason != "local_recovery")) ||
                (!r.recoveryConfirmed && r.lastRepairReason != "")) throw new InvalidDataException("Invalid recovery claim.");
        }
        public static AutoRepairResult Current(string root) { return Snapshot(root,false); }
        public static AutoRepairResult Snapshot(string root, bool previous)
        {
            try
            {
                Dictionary<string,object> doc=Read(Path.Combine(root,previous ? "auto-repair-state.previous.json" : "auto-repair-state.json"));
                if (!doc.ContainsKey("schema")) return null;
                return Json().Deserialize<AutoRepairResult>(Json().Serialize(doc));
            }
            catch { return null; }
        }
        public static void CheckExisting(string root)
        {
            string primary=Path.Combine(root,"auto-repair-state.json"),previous=Path.Combine(root,"auto-repair-state.previous.json");
            CheckPath(primary);CheckPath(previous);
            bool missing=false;
            try { Read(primary); } catch (FileNotFoundException) { missing=true; }
            try { Read(previous);if(missing) throw new InvalidDataException("Primary result missing."); } catch (FileNotFoundException) { }
        }
        public static string LegacyAttempt(string root)
        {
            try
            {
                Dictionary<string,object> doc=Read(Path.Combine(root,"auto-repair-state.json"));
                return doc.ContainsKey("schema") ? "" : (string)doc["lastRepairUtc"];
            }
            catch(FileNotFoundException) { return ""; }
        }
        public static void Save(string root, AutoRepairResult value)
        {
            Validate(value); CheckExisting(root);
            string path = Path.Combine(root,"auto-repair-state.json"), previous=Path.Combine(root,"auto-repair-state.previous.json");
            byte[] bytes = new UTF8Encoding(false).GetBytes(Json().Serialize(value));
            if (bytes.Length > 8192) throw new InvalidDataException("Result too large.");
            string scratch=path+"."+Guid.NewGuid().ToString("N")+".tmp";
            try
            {
                using (FileStream f=new FileStream(scratch,FileMode.CreateNew,FileAccess.Write,FileShare.None)) { f.Write(bytes,0,bytes.Length); f.Flush(true); }
                if (File.Exists(path)) File.Replace(scratch,path,previous); else File.Move(scratch,path);
            }
            finally { if (File.Exists(scratch)) File.Delete(scratch); }
            // Secondary typed history never controls whether the repair succeeded.
            AutoRepairBackground.Record(root,value,false);
        }
    }
    public static class AutoRepairWorker
    {
        private static bool Healthy(AutoHealth h) { return h != null && h.Service=="Running" && h.Client=="Running" && h.Backend=="Running" && h.Startup!="Disabled"; }
        private static string Fault(AutoHealth h)
        {
            if(h==null || h.Startup=="Disabled") return "";
            if(h.Backend=="Stopped" || h.Backend=="NeedsLogin" || h.Backend=="NeedsMachineAuth" || h.Backend=="InUseOtherUser") return "";
            if(h.Service=="Stopped" && (h.Startup=="Automatic" || h.Startup=="Manual")) return "service_stopped";
            if(h.Service!="Running") return "";
            if(h.Backend=="Starting") return "backend_starting";
            if(h.Backend=="NoState") return "backend_no_state";
            return h.Backend=="Running" && h.Client=="Closed" ? "client_closed" : "";
        }
        private static void Observed(AutoRepairResult r,AutoHealth h,DateTime now)
        {
            r.lastCheckedUtc=now.ToString("o",CultureInfo.InvariantCulture);
            r.service=h!=null && (h.Service=="Running" || h.Service=="Stopped" || h.Service=="Missing") ? h.Service : "Unknown";
            r.client=h!=null && (h.Client=="Running" || h.Client=="Closed") ? h.Client : "Unknown";
            r.backend=h==null ? "Unknown" : AutoRepairPolicy.Backend(h.Backend);
        }
        private sealed class Run
        {
            internal string Root;
            internal IAutoRepairMachine Machine;
            internal OperationLease Lease;
            internal AutoRepairResult Result;
            internal Stopwatch Watch=Stopwatch.StartNew();
            internal DateTime LastUtc;
            internal void Guard(bool mutate)
            {
                if(!Lease.IsCurrent) throw new InvalidOperationException("ownership_changed");
                DateTime now=Machine.UtcNow;
                if(now.Kind!=DateTimeKind.Utc || now<LastUtc) throw new InvalidOperationException("clock_changed");
                LastUtc=now;
                if(Watch.Elapsed.TotalSeconds>75 || !Machine.CanContinue) throw new InvalidOperationException("interrupted");
                bool? enabled=AutoRepairPolicyStore.ReadEnabled(Root);
                if(enabled!=true) throw new InvalidOperationException(enabled==false?"off":"settings_unavailable");
                if(mutate && !Machine.CanMutate) throw new InvalidOperationException("integration_unavailable");
            }
            internal AutoHealth Read()
            {
                Guard(false); AutoHealth h=Machine.Observe(); Guard(false);
                Observed(Result,h,Machine.UtcNow); return h;
            }
            internal void Save() { Guard(false); AutoRepairRecords.Save(Root,Result); }
            internal void Authorize(string expected)
            {
                AutoHealth fresh=Read();
                AutoDecision current=AutoRepairPolicyStore.Observe(Root,fresh,Machine.UtcNow,false);
                if(current.Action=="Attention") throw new InvalidOperationException(current.Reason);
                if(Fault(fresh)!=expected) throw new InvalidOperationException("observation_changed");
                AutoRepairRecords.CheckExisting(Root);
                Guard(true);
            }
            internal bool Act(string action,string expected)
            {
                Authorize(expected);
                Result.phase=action; Result.status="repairing"; Result.actionsAttempted++;
                Save(); // Durable evidence precedes the possible side effect.
                Action permission=delegate { Authorize(expected); };
                bool completed= action=="OpeningClient" ? Machine.OpenClient(permission) : action=="StartingService" ? Machine.StartService(permission) : Machine.StopService(permission);
                if(completed)
                {
                    Result.actionsCompleted++;
                    string code=action=="OpeningClient"?"client_opened":action=="StartingService"?"service_started":"service_stopped";
                    string at=Machine.UtcNow.ToString("o",CultureInfo.InvariantCulture);
                    if(Result.actionsCompleted==1){Result.action1=code;Result.action1Utc=at;}
                    else if(Result.actionsCompleted==2){Result.action2=code;Result.action2Utc=at;}
                    else {Result.action3=code;Result.action3Utc=at;}
                    Result.lastCheckedUtc=at;
                }
                Result.reason=completed?"action_completed":"action_unconfirmed";
                Save();
                return completed;
            }
        }
        public static AutoRepairResult Execute(string root,IAutoRepairMachine machine) { return ExecuteCore(root,machine,false); }
        public static AutoRepairResult ExecuteScheduled(string root,IAutoRepairMachine machine) { return ExecuteCore(root,machine,true); }
        private static AutoRepairResult ExecuteCore(string root,IAutoRepairMachine machine,bool scheduled)
        {
            AutoRepairResult result=new AutoRepairResult { runId=Guid.NewGuid().ToString("N"),lastCheckedUtc=DateTime.UtcNow.ToString("o") };
            Run run=null;
            try
            {
                AutoRepairRecords.CheckPath(root);
                if(!Directory.Exists(root) || machine==null) { result.reason="integration_unavailable"; return result; }
                bool? enabled=AutoRepairPolicyStore.ReadEnabled(root);
                if(enabled!=true) { result.status=enabled==false?"disabled":"manual"; result.reason=enabled==false?"off":"settings_unavailable"; return result; }
                // Existing maintenance kind: old-host compatible marker schema.
                OperationLease lease=OperationGate.TryAcquire(root,"maintenance");
                if(lease==null) { result.status="busy";result.reason="operation_busy";return result; }
                run=new Run { Root=root,Machine=machine,Lease=lease,Result=result,LastUtc=machine.UtcNow };
                run.Guard(false);
                AutoRepairRecords.CheckExisting(root);
                // No former worker can still own this lease. Reconcile bounded
                // prior snapshots before overwriting them, including uncertain exits.
                AutoRepairBackground.Reconcile(root,true);
                AutoRepairResult prior=AutoRepairRecords.Current(root);
                if(scheduled && prior!=null)
                {
                    double age=(machine.UtcNow-AutoRepairPolicy.Time(prior.lastCheckedUtc)).TotalSeconds;
                    if(age>=0 && age<30) return prior; // Persisted flood suppression; not a new observation.
                }
                AutoRepairPolicyStore.ImportLegacyAttempt(root,AutoRepairRecords.LegacyAttempt(root),machine.UtcNow);
                AutoHealth health=run.Read();
                AutoDecision decision=AutoRepairPolicyStore.Observe(root,health,machine.UtcNow,false);
                result.reason=decision.Reason;result.cooldownRemainingMinutes=decision.CooldownMinutes;
                result.status=decision.Action=="Healthy"?"healthy":decision.Action=="Attention"?"manual":decision.Action=="Cooldown"?"cooldown":"waiting";
                if(decision.Action!="RequestRepair") { result.phase="Complete";run.Save();return result; }
                result.phase="Reserved";result.reason=decision.Reason;
                result.reservedUtc=result.lastCheckedUtc=machine.UtcNow.ToString("o",CultureInfo.InvariantCulture);run.Save();
                bool action=false;
                if(decision.Reason=="client_closed") action=run.Act("OpeningClient",decision.Reason);
                else if(decision.Reason=="service_stopped") action=run.Act("StartingService",decision.Reason);
                else if(decision.Reason=="backend_starting" || decision.Reason=="backend_no_state")
                {
                    // Stop and start are separately guarded. Cancellation after stop
                    // leaves an honest partial result, never overrides the opt-out.
                    if(run.Act("StoppingService",decision.Reason)) action=run.Act("StartingService","service_stopped");
                }
                if(action)
                {
                    result.phase="Verifying";run.Save();
                    for(int i=0;i<10;i++)
                    {
                        health=run.Read();
                        if(Healthy(health)) break;
                        string fault=Fault(health);
                        if(fault=="client_closed" && result.actionsAttempted<3)
                        { if(!run.Act("OpeningClient","client_closed")) { action=false;break; } }
                        else if(health!=null && (health.Backend=="Stopped" || health.Backend=="NeedsLogin" || health.Backend=="NeedsMachineAuth" || health.Backend=="InUseOtherUser"))
                        { AutoRepairPolicyStore.Observe(root,health,machine.UtcNow,false);break; }
                        machine.Pause();
                    }
                }
                health=run.Read();
                result.recoveryConfirmed=action && result.actionsCompleted>0 && Healthy(health);
                result.status=Healthy(health)?"healthy":"manual";
                result.reason=result.recoveryConfirmed?"local_recovery":Healthy(health)?"local_running":"recovery_unconfirmed";
                if(result.recoveryConfirmed) { result.lastRepairUtc=result.lastCheckedUtc;result.lastRepairReason="local_recovery"; }
                result.phase="Complete";run.Save();
            }
            catch(Exception ex)
            {
                result.status=ex.Message=="off"?"disabled":"manual";result.recoveryConfirmed=false;result.lastRepairUtc=result.lastRepairReason="";
                result.reason=Array.IndexOf(new[] { "ownership_changed","clock_changed","interrupted","off","settings_unavailable","integration_unavailable","disconnected","sign_in","approval","other_user","service_disabled","installation_missing","state_unavailable","observation_changed" },ex.Message)>=0 ? ex.Message : "state_or_action_unavailable";
                result.phase="Complete";
                if(machine!=null && machine.UtcNow.Kind==DateTimeKind.Utc && machine.UtcNow>=AutoRepairPolicy.Time(result.lastCheckedUtc))
                    result.lastCheckedUtc=machine.UtcNow.ToString("o",CultureInfo.InvariantCulture);
                // Record cancellation only while still owning the operation and
                // the existing records remain readable. No force-reset on failure.
                if(run!=null && run.Lease.IsCurrent) try { AutoRepairRecords.Save(root,result); } catch { }
            }
            finally
            {
                if(run!=null) try { run.Lease.Dispose(); } catch { result.status="manual";result.reason="ownership_changed";result.recoveryConfirmed=false;result.lastRepairUtc=result.lastRepairReason=""; }
            }
            return result;
        }
    }
}
