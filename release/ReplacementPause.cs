using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Tqr.Acceptance
{
    // Test-only local file hold. No installer hooks, injected code or network I/O.
    // A read/handle oplock must require acknowledgement; advisory breaks do not count.
    public sealed class ReplacementPause : IDisposable
    {
        private const uint RequestOplock = 0x00090240;
        private const uint ReadHandleLevel = 3;
        private const uint AckRequired = 1;
        private const int IoPending = 997;
        private static readonly List<ReplacementPause> Undrained = new List<ReplacementPause>();
        private SafeFileHandle file;
        private ManualResetEvent signal;
        private IntPtr input, output, overlapped;
        private bool pending, disposed;

        [StructLayout(LayoutKind.Sequential)]
        private struct OverlappedData
        {
            internal IntPtr Internal, InternalHigh;
            internal uint Offset, OffsetHigh;
            internal IntPtr Event;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeviceIoControl(SafeFileHandle handle, uint control,
            IntPtr input, uint inputLength, IntPtr output, uint outputLength,
            IntPtr returned, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetOverlappedResult(SafeFileHandle handle,
            IntPtr overlapped, out uint transferred, [MarshalAs(UnmanagedType.Bool)] bool wait);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CancelIoEx(SafeFileHandle handle, IntPtr overlapped);

        private static IntPtr Allocate(int size)
        {
            IntPtr value = Marshal.AllocHGlobal(size);
            for (int i = 0; i < size; i++) Marshal.WriteByte(value, i, 0);
            return value;
        }

        public ReplacementPause(string path)
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8)
                throw new InvalidOperationException("Native x64 Windows file hold required.");
            string full = Path.GetFullPath(path);
            for (string part = full; !String.IsNullOrEmpty(part); part = Path.GetDirectoryName(part))
                if ((File.GetAttributes(part) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidOperationException("Redirected file hold refused.");
            if (!File.Exists(full)) throw new InvalidOperationException("Existing file required.");
            try
            {
                // GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING, OVERLAPPED and OPEN_REPARSE_POINT.
                // Compatible backup reads continue; a conflicting replacement must wait.
                file = CreateFile(full, 0x80000000, 1, IntPtr.Zero, 3, 0x40200000, IntPtr.Zero);
                if (file.IsInvalid) throw new InvalidOperationException("File hold open refused.");
                signal = new ManualResetEvent(false);
                input = Allocate(12); output = Allocate(24);
                Marshal.WriteInt16(input, 0, 1); Marshal.WriteInt16(input, 2, 12);
                Marshal.WriteInt32(input, 4, (int)ReadHandleLevel);
                Marshal.WriteInt32(input, 8, 1);
                overlapped = Allocate(Marshal.SizeOf(typeof(OverlappedData)));
                OverlappedData state = new OverlappedData();
                state.Event = signal.SafeWaitHandle.DangerousGetHandle();
                Marshal.StructureToPtr(state, overlapped, false);
                bool immediate = DeviceIoControl(file, RequestOplock, input, 12,
                    output, 24, IntPtr.Zero, overlapped);
                int error = Marshal.GetLastWin32Error();
                if (immediate || error != IoPending)
                    throw new InvalidOperationException("Acknowledged file hold was not granted.");
                pending = true;
            }
            catch { Dispose(); throw; }
        }

        public bool WaitForRequiredBreak(int milliseconds)
        {
            if (disposed || milliseconds < 1 || milliseconds > 5000)
                throw new InvalidOperationException("Bounded live file hold required.");
            if (!signal.WaitOne(milliseconds)) return false;
            uint transferred;
            if (!GetOverlappedResult(file, overlapped, out transferred, false) ||
                Marshal.ReadInt16(output, 0) != 1 || Marshal.ReadInt16(output, 2) != 24 ||
                (uint)Marshal.ReadInt32(output, 4) != ReadHandleLevel ||
                ((uint)Marshal.ReadInt32(output, 12) & AckRequired) == 0)
                throw new InvalidOperationException("Nonblocking or failed file break refused.");
            return true;
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            bool drained = !pending;
            if (pending)
            {
                CancelIoEx(file, overlapped);
                drained = signal.WaitOne(5000);
            }
            if (file != null) file.Dispose();
            if (!drained) drained = signal.WaitOne(5000);
            if (!drained)
            {
                // Never free an OVERLAPPED or event still reachable by native I/O.
                lock (Undrained) Undrained.Add(this);
                throw new InvalidOperationException("File hold cancellation exceeded its bound.");
            }
            if (signal != null) signal.Dispose();
            foreach (IntPtr value in new IntPtr[] { input, output, overlapped })
                if (value != IntPtr.Zero) Marshal.FreeHGlobal(value);
            input = output = overlapped = IntPtr.Zero;
        }
    }

    public static class ReplacementPauseProbe
    {
        private static void Require(bool value)
        {
            if (!value) throw new InvalidOperationException("Synthetic file hold assertion failed.");
        }

        public static int Run(string root)
        {
            string full = Path.GetFullPath(root);
            Require(Directory.Exists(full) && Directory.GetFileSystemEntries(full).Length == 0);
            for (string part = full; !String.IsNullOrEmpty(part); part = Path.GetDirectoryName(part))
                Require((File.GetAttributes(part) & FileAttributes.ReparsePoint) == 0);
            string target = Path.Combine(full, "target.dat");
            string next = Path.Combine(full, "replacement.dat");
            string backup = Path.Combine(full, "readback.dat");
            File.WriteAllText(target, "synthetic-before");
            File.WriteAllText(next, "synthetic-after");
            ReplacementPause pause = null;
            Thread worker = null, reader = null;
            Exception workerFailure = null, readerFailure = null;
            ManualResetEvent entered = new ManualResetEvent(false);
            int checks = 0;
            try
            {
                pause = new ReplacementPause(target);
                reader = new Thread(delegate()
                {
                    try { File.Copy(target, backup); }
                    catch (Exception ex) { readerFailure = ex; }
                });
                reader.IsBackground = true;
                reader.Start();
                Require(reader.Join(5000) && readerFailure == null);
                Require(File.ReadAllText(backup) == "synthetic-before"); checks++;
                Require(!pause.WaitForRequiredBreak(25)); checks++;
                worker = new Thread(delegate()
                {
                    entered.Set();
                    try { File.Replace(next, target, null); }
                    catch (Exception ex) { workerFailure = ex; }
                });
                worker.IsBackground = true;
                worker.Start();
                Require(entered.WaitOne(5000)); checks++;
                Require(pause.WaitForRequiredBreak(5000)); checks++;
                Require(!worker.Join(250)); checks++;
                // Do not issue fresh reads of a file while its break awaits acknowledgement.
                pause.Dispose(); pause = null;
                Require(worker.Join(5000) && workerFailure == null); checks++;
                Require(File.ReadAllText(target) == "synthetic-after"); checks++;
                Require(!File.Exists(next) && File.ReadAllText(backup) == "synthetic-before"); checks++;
                pause = new ReplacementPause(target);
                Require(!pause.WaitForRequiredBreak(25)); checks++;
                pause.Dispose(); pause.Dispose(); pause = null;
                Require(File.ReadAllText(target) == "synthetic-after"); checks++;
                return checks;
            }
            finally
            {
                try { if (pause != null) pause.Dispose(); }
                finally
                {
                    bool stopped = worker == null || !worker.IsAlive || worker.Join(5000);
                    bool readStopped = reader == null || !reader.IsAlive || reader.Join(5000);
                    if (stopped) entered.Dispose();
                    Require(stopped && readStopped);
                }
            }
        }
    }
}
