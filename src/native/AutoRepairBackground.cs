using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace Tqr
{
    // Frozen, typed projections only. No raw worker text, target or process ID is
    // written into History. Existing 40-entry / 30-day limits remain authoritative.
    public static class AutoRepairBackground
    {
        private static HistoryEntry Entry(AutoRepairResult r,string slot,string code,string utc)
        {
            byte[] digest;
            using(SHA256 hash=SHA256.Create()) digest=hash.ComputeHash(Encoding.UTF8.GetBytes(r.runId+":"+slot));
            byte[] id=new byte[16];Array.Copy(digest,id,16);
            return new HistoryEntry { id=new Guid(id).ToString("N"),utc=utc,code=code,before=-1,after=-1 };
        }
        internal static bool Record(string root,AutoRepairResult r,bool abandoned)
        {
            try
            {
                if(r==null || r.schema!=3 || r.reservedUtc=="") return true;
                List<HistoryEntry> events=new List<HistoryEntry>();
                events.Add(Entry(r,"reserved","auto_attempt",r.reservedUtc));
                string[] actions={r.action1,r.action2,r.action3},stamps={r.action1Utc,r.action2Utc,r.action3Utc};
                for(int i=0;i<r.actionsCompleted;i++)
                    events.Add(Entry(r,"action"+i.ToString(CultureInfo.InvariantCulture),"auto_"+actions[i],stamps[i]));
                if(r.phase=="Complete")
                    events.Add(Entry(r,"outcome",r.recoveryConfirmed?"auto_recovered":"auto_unconfirmed",r.lastCheckedUtc));
                else if(abandoned)
                    events.Add(Entry(r,"outcome","auto_interrupted",r.lastCheckedUtc));
                return LocalHistory.RecordBatch(root,events.ToArray());
            }
            catch { return false; } // Secondary evidence cannot fail core recovery.
        }
        public static bool Reconcile(string root,bool abandoned)
        {
            try
            {
                AutoRepairRecords.CheckExisting(root);
                AutoRepairResult current=AutoRepairRecords.Current(root),previous=AutoRepairRecords.Snapshot(root,true);
                if(abandoned)
                {
                    OperationState owner=OperationGate.Inspect(root);
                    if(owner==null || owner.ownerPid!=Process.GetCurrentProcess().Id || owner.kind!="maintenance") return false;
                }
                bool ok=true;
                // A current completed snapshot supersedes its earlier progress,
                // which must never be relabelled as an interrupted second event.
                if(previous!=null && (current==null || previous.runId!=current.runId)) ok=Record(root,previous,abandoned);
                if(current!=null) ok=Record(root,current,abandoned) && ok;
                return ok;
            }
            catch { return false; }
        }
    }

    // One resident-UI episode with at most two dispatch attempts. All time comes
    // from a monotonic stopwatch; UTC clock changes cannot bypass the spacing.
    // This queues local checks, never decides whether networking should change.
    public sealed class AutoRepairEventQueue
    {
        private long due=-1,expires,lastAttempt=-30000,lastTick=-1;
        private int attempts;
        public bool Pending { get { return due>=0; } }
        public void Cancel() { due=-1;attempts=0; } // Keep lastAttempt across toggles.
        public void Signal(long now,int delaySeconds,bool enabled)
        {
            if(!enabled || now<0) { Cancel();return; }
            long delay=(long)Math.Max(10,Math.Min(30,delaySeconds))*1000;
            if(!Pending) { attempts=0;expires=now+120000;due=Math.Max(now+delay,lastAttempt+30000); }
            else due=Math.Max(due,now+delay); // Settling follows the newest event.
        }
        public bool Take(long now,bool enabled,bool busy)
        {
            if(now<0 || !enabled) { Cancel();return false; }
            if(lastTick>=0 && now<lastTick) { Cancel();lastTick=now;return false; }
            bool gap=lastTick>=0 && now-lastTick>25000;
            lastTick=now;
            if(!Pending) return false;
            if(now>expires) { Cancel();return false; }
            if(gap) due=Math.Max(due,now+30000);
            if(now<due) return false;
            if(busy) { due=now+10000;return false; }
            if(now-lastAttempt<30000) { due=lastAttempt+30000;return false; }
            lastAttempt=now;attempts++;
            if(attempts>=2) due=-1;
            else due=now+60000; // One bounded follow-up to confirm a local fault.
            return true;
        }
    }
}
