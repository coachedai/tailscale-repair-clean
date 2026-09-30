using System;
using System.Runtime.InteropServices;
using System.Text;

// Test-only window access. Text is read only after the owning process is checked.
public static class SetupEntryProbe
{
    private delegate bool EnumProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wparam, StringBuilder text, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int maximum);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wparam, IntPtr lparam, uint flags, uint timeout, out IntPtr result);

    private static bool Owned(IntPtr window, int process)
    {
        uint owner;
        return process > 0 && window != IntPtr.Zero && GetWindowThreadProcessId(window, out owner) != 0 && owner == (uint)process;
    }

    private static string Text(IntPtr window)
    {
        StringBuilder buffer = new StringBuilder(1024);
        IntPtr result;
        return SendMessageTimeout(window, 0x000D, new IntPtr(buffer.Capacity), buffer, 2, 500, out result) != IntPtr.Zero ? buffer.ToString() : String.Empty;
    }

    public static IntPtr Find(int process, string title, string classPrefix)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr unused)
        {
            if (!Owned(window, process) || !IsWindowVisible(window)) return true;
            if (!String.Equals(Text(window), title, StringComparison.Ordinal)) return true;
            StringBuilder kind = new StringBuilder(256);
            GetClassName(window, kind, kind.Capacity);
            if (!kind.ToString().StartsWith(classPrefix, StringComparison.Ordinal)) return true;
            found = window;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    public static bool Contains(IntPtr parent, int process, string expected)
    {
        if (!Owned(parent, process)) return false;
        bool found = false;
        int count = 0;
        EnumChildWindows(parent, delegate(IntPtr window, IntPtr unused)
        {
            if (++count > 256) return false;
            if (Owned(window, process) && Text(window).Contains(expected)) { found = true; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool Click(IntPtr parent, int process, string caption)
    {
        if (!Owned(parent, process)) return false;
        IntPtr button = IntPtr.Zero;
        int count = 0;
        EnumChildWindows(parent, delegate(IntPtr window, IntPtr unused)
        {
            if (++count > 256) return false;
            if (!Owned(window, process)) return true;
            StringBuilder kind = new StringBuilder(256);
            GetClassName(window, kind, kind.Capacity);
            if (kind.ToString().IndexOf("Button", StringComparison.OrdinalIgnoreCase) < 0) return true;
            if (Text(window).Replace("&", "") != caption) return true;
            button = window;
            return false;
        }, IntPtr.Zero);
        return Owned(button, process) && PostMessage(button, 0x00F5, IntPtr.Zero, IntPtr.Zero);
    }

    public static bool Close(IntPtr window, int process)
    {
        return Owned(window, process) && PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero);
    }

    public static bool Responsive(IntPtr window, int process)
    {
        IntPtr result;
        return Owned(window, process) && SendMessageTimeout(window, 0, IntPtr.Zero, IntPtr.Zero, 2, 1000, out result) != IntPtr.Zero;
    }
}
