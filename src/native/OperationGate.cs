using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

// Used by the native hosts and by both PowerShell workers. This coordinates
// operations; it is not a security boundary against another local process.
namespace Tqr
{
    public sealed class OperationState
    {
        public string kind;
        public int ownerPid;
    }

    public sealed class OperationLease : IDisposable
    {
        internal string DirectoryPath;
        internal string Id;
        public string Kind { get; internal set; }
        private bool disposed;
        public bool IsCurrent { get { return !disposed && OperationGate.Owns(this); } }

        public void Dispose()
        {
            if (disposed) return;
            OperationGate.Release(this);
            disposed = true;
        }
    }

    public static class OperationGate
    {
        private const string Marker = "operation.lock";
        private const string Gate = "operation-coordinator.gate";
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);

        private static JavaScriptSerializer Serializer()
        {
            return new JavaScriptSerializer { MaxJsonLength = 8192, RecursionLimit = 8 };
        }

        private static string Root(string directory)
        {
            string root = Path.GetFullPath(directory);
            Directory.CreateDirectory(root);
            RefuseReparse(root);
            RefuseReparse(Path.Combine(root, Gate));
            RefuseReparse(Path.Combine(root, Marker));
            return root;
        }

        private static void RefuseReparse(string path)
        {
            if ((File.Exists(path) || Directory.Exists(path)) &&
                (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Quick Repair operation metadata cannot use a reparse point.");
        }

        private static FileStream Enter(string root, int waitMilliseconds)
        {
            Stopwatch watch = Stopwatch.StartNew();
            while (true)
            {
                try
                {
                    // This file is deliberately never deleted: deleting a mutex
                    // pathname can split two processes onto different file objects.
                    return new FileStream(Path.Combine(root, Gate), FileMode.OpenOrCreate,
                        FileAccess.ReadWrite, FileShare.None);
                }
                catch (IOException ex)
                {
                    int code = ex.HResult & 0xffff;
                    if (code != 32 && code != 33) throw;
                    if (watch.ElapsedMilliseconds >= waitMilliseconds) return null;
                    Thread.Sleep(5);
                }
            }
        }

        private static Dictionary<string, object> Read(string root)
        {
            string path = Path.Combine(root, Marker);
            if (!File.Exists(path)) return null;
            RefuseReparse(path);
            long length = new FileInfo(path).Length;
            if (length < 2 || length > 8192)
                throw new InvalidDataException("Operation metadata is incomplete; it has been preserved.");
            Dictionary<string, object> info = Serializer().Deserialize<Dictionary<string, object>>(
                File.ReadAllText(path, Utf8));
            if (info == null || !info.ContainsKey("schema") ||
                !info.ContainsKey("ownerPid") || !info.ContainsKey("kind"))
                throw new InvalidDataException("Operation metadata is invalid; it has been preserved.");
            int schema = Convert.ToInt32(info["schema"]);
            if ((schema != 1 && schema != 2) || Convert.ToInt32(info["ownerPid"]) <= 0 ||
                !AllowedKind(Convert.ToString(info["kind"])))
                throw new InvalidDataException("Operation ownership cannot be verified; the marker was preserved.");
            if (schema == 2 && (!info.ContainsKey("leaseId") || !info.ContainsKey("ownerStartTicks") ||
                Convert.ToInt64(info["ownerStartTicks"]) <= 0 ||
                !ValidId(Convert.ToString(info["leaseId"]))))
                throw new InvalidDataException("Operation identity is invalid; it has been preserved.");
            return info;
        }

        private static bool ValidId(string value)
        {
            Guid parsed;
            return Guid.TryParseExact(value, "N", out parsed);
        }

        private static bool AllowedKind(string kind)
        {
            return kind == "repair" || kind == "diagnostics" || kind == "update" ||
                kind == "setup" || kind == "maintenance" || kind == "integrity";
        }

        private static OperationState LiveOwner(Dictionary<string, object> info)
        {
            if (info == null) return null;
            int pid = Convert.ToInt32(info["ownerPid"]);
            string kind = Convert.ToString(info["kind"]);
            try
            {
                using (Process process = Process.GetProcessById(pid))
                {
                    if (process.HasExited) return null;
                    if (info.ContainsKey("ownerStartTicks") &&
                        process.StartTime.ToUniversalTime().Ticks != Convert.ToInt64(info["ownerStartTicks"]))
                        return null; // The PID was reused, not the recorded owner.
                    return new OperationState { kind = kind, ownerPid = pid };
                }
            }
            catch (ArgumentException) { return null; } // PID no longer exists.
            catch
            {
                // Access denied or an uncertain process query is NOT proof of death.
                return new OperationState { kind = kind, ownerPid = pid };
            }
        }

        public static OperationState Inspect(string directory)
        {
            string root = Root(directory);
            using (FileStream guard = Enter(root, 0))
            {
                if (guard == null)
                    return new OperationState { kind = "another operation", ownerPid = 0 };
                // Inspection never removes markers, even when the owner is gone.
                return LiveOwner(Read(root));
            }
        }

        public static OperationLease TryAcquire(string directory, string kind)
        {
            if (!AllowedKind(kind)) throw new ArgumentException("Unsupported Quick Repair operation.");
            string root = Root(directory);
            using (FileStream guard = Enter(root, 0))
            {
                if (guard == null) return null;
                Dictionary<string, object> previous = Read(root);
                if (LiveOwner(previous) != null) return null;
                if (previous != null)
                {
                    // Only a proven-dead owner reaches this point. Keep a bounded,
                    // local recovery record before replacing its abandoned marker.
                    Dictionary<string, object> recovery = new Dictionary<string, object>();
                    recovery["schema"] = 1;
                    recovery["kind"] = Convert.ToString(previous["kind"]);
                    recovery["ownerPid"] = Convert.ToInt32(previous["ownerPid"]);
                    recovery["recoveredUtc"] = DateTime.UtcNow.ToString("o");
                    WriteAtomic(Path.Combine(root, "operation-recovery.json"), recovery);
                }

                string id = Guid.NewGuid().ToString("N");
                Dictionary<string, object> info = new Dictionary<string, object>();
                using (Process self = Process.GetCurrentProcess())
                {
                    info["schema"] = 2;
                    info["kind"] = kind;
                    info["ownerPid"] = self.Id;
                    info["ownerStartTicks"] = self.StartTime.ToUniversalTime().Ticks;
                    info["leaseId"] = id;
                    info["startedUtc"] = DateTime.UtcNow.ToString("o");
                }
                WriteAtomic(Path.Combine(root, Marker), info);
                return new OperationLease { DirectoryPath = root, Id = id, Kind = kind };
            }
        }

        internal static bool Owns(OperationLease lease)
        {
            try
            {
                string root = Root(lease.DirectoryPath);
                using (FileStream guard = Enter(root, 0))
                {
                    if (guard == null) return false;
                    Dictionary<string, object> info = Read(root);
                    using (Process self = Process.GetCurrentProcess())
                    {
                        return info != null && info.ContainsKey("leaseId") && info.ContainsKey("ownerStartTicks") &&
                            String.Equals(Convert.ToString(info["leaseId"]), lease.Id, StringComparison.Ordinal) &&
                            Convert.ToInt32(info["ownerPid"]) == self.Id &&
                            Convert.ToInt64(info["ownerStartTicks"]) == self.StartTime.ToUniversalTime().Ticks;
                    }
                }
            }
            catch { return false; }
        }

        internal static void Release(OperationLease lease)
        {
            string root = Root(lease.DirectoryPath);
            using (FileStream guard = Enter(root, 2000))
            {
                if (guard == null) throw new IOException("Operation cleanup is busy; ownership was preserved.");
                Dictionary<string, object> info = Read(root);
                if (info == null) return;
                if (!info.ContainsKey("leaseId") ||
                    !String.Equals(Convert.ToString(info["leaseId"]), lease.Id, StringComparison.Ordinal))
                    throw new IOException("Operation ownership changed; the other marker was not removed.");
                File.Delete(Path.Combine(root, Marker));
            }
        }

        private static void WriteAtomic(string path, Dictionary<string, object> value)
        {
            RefuseReparse(path);
            string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                byte[] bytes = Utf8.GetBytes(Serializer().Serialize(value));
                using (FileStream stream = new FileStream(temp, FileMode.CreateNew,
                    FileAccess.Write, FileShare.None))
                {
                    stream.Write(bytes, 0, bytes.Length);
                    stream.Flush(true);
                }
                if (File.Exists(path)) File.Replace(temp, path, null);
                else File.Move(temp, path);
            }
            finally
            {
                if (File.Exists(temp)) File.Delete(temp); // Only this call's scratch file.
            }
        }
    }
}
