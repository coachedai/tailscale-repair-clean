using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace Tqr
{
    // Bounded, local, typed product events. No raw logs, peer addresses, names,
    // arbitrary messages or network requests belong in this store.
    public sealed class HistoryEntry
    {
        public string id;
        public string utc;
        public string code;
        public int before;
        public int after;
    }
    public sealed class HistoryView
    {
        public string Status;
        public HistoryEntry[] Entries;
    }
    public static class LocalHistory
    {
        private const int Limit = 40;
        private const int ByteLimit = 32768;
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        private static readonly HashSet<string> Codes = new HashSet<string>(StringComparer.Ordinal) {
            "check_healthy", "check_attention", "repair_completed", "route_direct", "route_relay",
            "latency_up", "latency_down", "update_installed", "update_failed", "integrity_ok",
            "integrity_attention", "target_changed", "environment_changed", "recovery_observed", "vpn_active", "vpn_inactive", "vpn_changed", "auto_attempt", "auto_client_opened",
            "auto_service_started", "auto_service_stopped", "auto_recovered", "auto_unconfirmed", "auto_interrupted"
        };
        private static string Root(string directory)
        {
            string root = Path.GetFullPath(directory);
            if (!Path.IsPathRooted(directory) || root.StartsWith(@"\\",StringComparison.Ordinal) || root.IndexOf(':',2)>=0)
                throw new IOException("Local history path required.");
            for (string p=root; !String.IsNullOrEmpty(p); p=Path.GetDirectoryName(p))
            {
                try { if((File.GetAttributes(p) & FileAttributes.ReparsePoint)!=0) throw new IOException("History ancestor is a reparse point."); }
                catch(FileNotFoundException) { } catch(DirectoryNotFoundException) { }
            }
            Directory.CreateDirectory(root);
            foreach (string path in new [] { root, Path.Combine(root,"health-history.json"),
                Path.Combine(root,"health-history.previous.json"), Path.Combine(root,"health-history.gate") })
            {
                if ((File.Exists(path) || Directory.Exists(path)) &&
                    (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("History path uses a reparse point.");
            }
            return root;
        }
        private static FileStream Gate(string root)
        {
            return new FileStream(Path.Combine(root,"health-history.gate"), FileMode.OpenOrCreate,
                FileAccess.ReadWrite, FileShare.None);
        }
        private static JavaScriptSerializer Json()
        {
            return new JavaScriptSerializer { MaxJsonLength=ByteLimit, RecursionLimit=8 };
        }
        private static bool ValidValue(int value) { return value >= -1 && value <= 600000; }
        private static List<HistoryEntry> Load(string root)
        {
            string path = Path.Combine(root,"health-history.json");
            try { return LoadFile(path); }
            catch(FileNotFoundException)
            {
                string previous=Path.Combine(root,"health-history.previous.json");
                if(File.Exists(previous) || Directory.Exists(previous)) throw new InvalidDataException("Primary history missing.");
                return new List<HistoryEntry>();
            }
        }
        private static List<HistoryEntry> LoadFile(string path)
        {
            long size = new FileInfo(path).Length;
            if (size < 2 || size > ByteLimit) throw new InvalidDataException("History size is invalid.");
            Dictionary<string,object> doc = Json().Deserialize<Dictionary<string,object>>(File.ReadAllText(path,Utf8));
            if (doc == null || doc.Count != 2 || !doc.ContainsKey("schema") ||
                !(doc["schema"] is int) || (int)doc["schema"] != 1 || !doc.ContainsKey("entries"))
                throw new InvalidDataException("History schema is invalid.");
            object[] array = doc["entries"] as object[];
            if (array == null) {
                System.Collections.ArrayList list = doc["entries"] as System.Collections.ArrayList;
                if (list != null) array = list.ToArray();
            }
            if (array == null || array.Length > Limit) throw new InvalidDataException("History count is invalid.");
            List<HistoryEntry> result = new List<HistoryEntry>();
            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (object item in array)
            {
                Dictionary<string,object> fields = item as Dictionary<string,object>;
                if (fields == null || fields.Count != 5 || !fields.ContainsKey("id") || !fields.ContainsKey("utc") ||
                    !fields.ContainsKey("code") || !fields.ContainsKey("before") || !fields.ContainsKey("after"))
                    throw new InvalidDataException("History fields are invalid.");
                if (!(fields["id"] is string) || !(fields["utc"] is string) || !(fields["code"] is string) ||
                    !(fields["before"] is int) || !(fields["after"] is int)) throw new InvalidDataException("History types are invalid.");
                HistoryEntry entry = new HistoryEntry { id=Convert.ToString(fields["id"]), utc=Convert.ToString(fields["utc"]),
                    code=Convert.ToString(fields["code"]), before=Convert.ToInt32(fields["before"]), after=Convert.ToInt32(fields["after"]) };
                Guid id; DateTime stamp;
                if (!Guid.TryParseExact(entry.id,"N",out id) || !seen.Add(entry.id) || !Codes.Contains(entry.code) ||
                    !ValidValue(entry.before) || !ValidValue(entry.after) ||
                    !DateTime.TryParseExact(entry.utc,"o",CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind,out stamp) ||
                    stamp.Kind != DateTimeKind.Utc || stamp > DateTime.UtcNow.AddMinutes(5))
                    throw new InvalidDataException("History entry is invalid.");
                result.Add(entry);
            }
            return result;
        }
        private static void Prune(List<HistoryEntry> entries)
        {
            DateTime cutoff=DateTime.UtcNow.AddDays(-30);
            entries.RemoveAll(delegate(HistoryEntry x) {
                return DateTime.ParseExact(x.utc,"o",CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind) < cutoff;
            });
            if (entries.Count > Limit) entries.RemoveRange(0,entries.Count-Limit);
        }
        public static HistoryView Read(string directory)
        {
            try {
                string root=Root(directory);
                using (FileStream guard=Gate(root)) {
                    List<HistoryEntry> entries=Load(root); Prune(entries); entries.Reverse();
                    return new HistoryView { Status="ready", Entries=entries.ToArray() };
                }
            } catch {
                return new HistoryView { Status="unavailable", Entries=new HistoryEntry[0] };
            }
        }
        public static bool Record(string directory, string code, int before, int after)
        {
            if (!Codes.Contains(code) || !ValidValue(before) || !ValidValue(after)) return false;
            try {
                string root=Root(directory);
                using (FileStream guard=Gate(root)) {
                    List<HistoryEntry> entries=Load(root); Prune(entries);
                    if (entries.Count > 0) {
                        HistoryEntry last=entries[entries.Count-1];
                        DateTime at=DateTime.ParseExact(last.utc,"o",CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind);
                        if (last.code == code && last.before == before && last.after == after &&
                            (DateTime.UtcNow-at).TotalSeconds < 60) return true;
                    }
                    entries.Add(new HistoryEntry { id=Guid.NewGuid().ToString("N"), utc=DateTime.UtcNow.ToString("o"),
                        code=code, before=before, after=after });
                    Prune(entries);
                    Save(root,entries);
                    return true;
                }
            } catch { return false; } // Secondary history must never break a repair.
        }
        private static void Save(string root,List<HistoryEntry> entries)
        {
            string predecessor=Path.Combine(root,"health-history.previous.json");
            try { LoadFile(predecessor); } catch(FileNotFoundException) { }
            Dictionary<string,object> doc=new Dictionary<string,object>();
            doc["schema"]=1; doc["entries"]=entries.ToArray();
            byte[] data=Utf8.GetBytes(Json().Serialize(doc));
            if (data.Length > ByteLimit) throw new InvalidDataException("History too large.");
            string path=Path.Combine(root,"health-history.json");
            string temp=path+"."+Guid.NewGuid().ToString("N")+".tmp";
            try {
                using (FileStream stream=new FileStream(temp,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
                    stream.Write(data,0,data.Length); stream.Flush(true);
                }
                if (File.Exists(path)) File.Replace(temp,path,Path.Combine(root,"health-history.previous.json"));
                else File.Move(temp,path);
            } finally { if(File.Exists(temp)) File.Delete(temp); }
        }
        // Stable event IDs make replay after a worker exit or an interrupted write
        // idempotent while keeping the existing five-field history schema.
        public static bool RecordBatch(string directory,HistoryEntry[] batch)
        {
            if(batch==null || batch.Length>6) return false;
            if(batch.Length==0) return true;
            try
            {
                DateTime now=DateTime.UtcNow;
                HashSet<string> ids=new HashSet<string>(StringComparer.Ordinal);
                foreach(HistoryEntry e in batch)
                {
                    Guid id; DateTime stamp;
                    if(e==null || !Guid.TryParseExact(e.id,"N",out id) || !ids.Add(e.id) || !Codes.Contains(e.code) ||
                        !ValidValue(e.before) || !ValidValue(e.after) ||
                        !DateTime.TryParseExact(e.utc,"o",CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind,out stamp) ||
                        stamp.Kind!=DateTimeKind.Utc || stamp>now.AddSeconds(5)) return false;
                }
                string root=Root(directory);
                using(FileStream guard=Gate(root))
                {
                    List<HistoryEntry> entries=Load(root);Prune(entries);
                    bool changed=false;
                    foreach(HistoryEntry e in batch)
                    {
                        DateTime stamp=DateTime.ParseExact(e.utc,"o",CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind);
                        if(stamp<now.AddDays(-30)) continue;
                        HistoryEntry same=entries.Find(delegate(HistoryEntry x){return x.id==e.id;});
                        if(same!=null)
                        {
                            if(same.code!=e.code || same.utc!=e.utc || same.before!=e.before || same.after!=e.after) return false;
                            continue;
                        }
                        // Never resurrect activity already evicted by the 40-event limit.
                        if(entries.Count>=Limit && StringComparer.Ordinal.Compare(e.utc,entries[0].utc)<0) continue;
                        int at=entries.FindIndex(delegate(HistoryEntry x){return StringComparer.Ordinal.Compare(x.utc,e.utc)>0;});
                        HistoryEntry copy=new HistoryEntry { id=e.id,utc=e.utc,code=e.code,before=e.before,after=e.after };
                        if(at<0) entries.Add(copy);else entries.Insert(at,copy);
                        Prune(entries);changed=true;
                    }
                    if(changed) Save(root,entries);
                    return true;
                }
            }
            catch { return false; }
        }
        public static string Describe(HistoryEntry entry)
        {
            if (entry == null || !Codes.Contains(entry.code)) return "";
            switch (entry.code) {
                case "auto_attempt": return "Automatic local recovery attempt reserved";
                case "auto_client_opened": return "Automatic repair opened the Tailscale client";
                case "auto_service_started": return "Automatic repair started the Tailscale service";
                case "auto_service_stopped": return "Automatic repair stopped the Tailscale service";
                case "auto_recovered": return "Automatic local recovery confirmed";
                case "auto_unconfirmed": return "Automatic recovery ended without confirmation";
                case "auto_interrupted": return "Previous automatic recovery has no recorded completion";
                case "check_healthy": return "Connection check passed";
                case "check_attention": return "Connection check needs attention";
                case "repair_completed": return "Repair actions performed";
                case "route_direct": return "Connection changed to Direct";
                case "route_relay": return "Connection changed to Relay";
                case "latency_up": return "Latency increased: " + entry.before + " to " + entry.after + " ms";
                case "latency_down": return "Latency improved: " + entry.before + " to " + entry.after + " ms";
                case "update_installed": return "App update installed";
                case "update_failed": return "App update needs attention";
                case "integrity_ok": return "App integrity verified";
                case "integrity_attention": return "App integrity needs attention";
                case "target_changed": return "Check target changed";
                case "environment_changed": return "Network environment changed";
                case "recovery_observed": return "Abandoned operation recovered";
                case "vpn_active": return "VPN became active";
                case "vpn_inactive": return "VPN became inactive";
                case "vpn_changed": return "Active VPN changed";
                default: return "";
            }
        }
    }
}
