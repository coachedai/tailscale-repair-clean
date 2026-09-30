using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

internal static class PublicSetupEntry
{
    private const string DetachedPrefix = "TailscaleQuickRepair-Setup-Detached-";
    private const string SelfTestAppDirEnvironment = "TQR_SETUP_RELOCATION_TEST_APPDIR";
    private const int MoveFileDelayUntilReboot = 0x00000004;

    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileEx(
        string existingFileName,
        string newFileName,
        int flags
    );

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (HasSwitch(args, "--self-test-relocation-child"))
            {
                return RunRelocationSelfTestChild(args);
            }

            if (HasSwitch(args, "--self-test-relocation-parent"))
            {
                return RunRelocationSelfTestParent(args);
            }

            // build-public.ps1 already invokes this switch for every Setup
            // build. Make it prove self-relocation as well as the host's basic
            // manifest/HTTPS configuration so the lock regression stays
            // release-blocking permanently.
            if (HasSwitch(args, "--self-test-installer"))
            {
                return RunInstallerSelfTest();
            }

            CleanupStaleDetachedCopies();

            if (IsDetachedSetupCopy())
            {
                ScheduleDetachedCleanup();
            }

            bool repairOnly = HasSwitch(args, "--repair");

            if (HasSwitch(args, "--upgrade"))
            {
                // Preserve the complete verified handoff across Setup's own
                // self-relocation. PublicSetupHost resolves peer/startup for
                // upgrade mode; channel, target code and requester SID must
                // survive unchanged.
                args = PreserveUpgradeArguments(args);
                repairOnly = false;
            }

            // Protected installs replace the Setup executable itself. If Setup
            // is running from Quick Repair's installed app directory, detach
            // first so Windows releases that file before the verified package
            // transaction attempts to replace it. Repair-only runs do not
            // replace files and therefore do not need relocation.
            if (
                !repairOnly &&
                !HasSwitch(args, "--setup-detached") &&
                IsRunningFromInstalledSetup()
            )
            {
                return RelaunchDetached(args);
            }

            return InvokeSetupHost(args);
        }
        catch (TargetInvocationException ex)
        {
            Exception inner = ex.InnerException ?? ex;
            try
            {
                System.Windows.Forms.MessageBox.Show(
                    "Quick Repair Setup could not start.\r\n\r\n" + inner.Message,
                    "Tailscale Quick Repair Setup",
                    System.Windows.Forms.MessageBoxButtons.OK,
                    System.Windows.Forms.MessageBoxIcon.Error
                );
            }
            catch { }
            return 33;
        }
        catch (Exception ex)
        {
            try
            {
                System.Windows.Forms.MessageBox.Show(
                    "Quick Repair Setup could not start.\r\n\r\n" + ex.Message,
                    "Tailscale Quick Repair Setup",
                    System.Windows.Forms.MessageBoxButtons.OK,
                    System.Windows.Forms.MessageBoxIcon.Error
                );
            }
            catch { }
            return 34;
        }
    }

    internal static string[] PreserveUpgradeArguments(string[] args)
    {
        if (args == null) return new string[0];
        string[] copy = new string[args.Length];
        Array.Copy(args, copy, args.Length);
        return copy;
    }

    private static int InvokeSetupHost(string[] args)
    {
        MethodInfo main = typeof(PublicSetupHost).GetMethod(
            "Main",
            BindingFlags.Static | BindingFlags.NonPublic
        );

        if (main == null)
        {
            return 31;
        }

        object result = main.Invoke(null, new object[] { args });
        return result is int ? (int)result : 32;
    }

    private static int RelaunchDetached(string[] args)
    {
        string current = GetCurrentExecutablePath();
        string detached = Path.Combine(
            Path.GetTempPath(),
            DetachedPrefix + Guid.NewGuid().ToString("N") + ".exe"
        );

        File.Copy(current, detached, true);

        List<string> childArgs = new List<string>();

        if (args != null)
        {
            foreach (string arg in args)
            {
                childArgs.Add(arg);
            }
        }

        if (!HasSwitch(args, "--setup-detached"))
        {
            childArgs.Add("--setup-detached");
        }

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = detached;
        psi.Arguments = JoinArguments(childArgs.ToArray());
        psi.WorkingDirectory = Path.GetDirectoryName(detached);
        psi.UseShellExecute = true;

        Process child = Process.Start(psi);
        return child == null ? 35 : 0;
    }

    private static bool IsRunningFromInstalledSetup()
    {
        string current = Path.GetFullPath(GetCurrentExecutablePath());
        string installed = Path.GetFullPath(
            Path.Combine(GetAppDir(), "TailscaleQuickRepairSetup.exe")
        );

        return String.Equals(
            current,
            installed,
            StringComparison.OrdinalIgnoreCase
        );
    }

    private static bool IsDetachedSetupCopy()
    {
        try
        {
            string name = Path.GetFileName(GetCurrentExecutablePath());
            return name.StartsWith(
                DetachedPrefix,
                StringComparison.OrdinalIgnoreCase
            );
        }
        catch
        {
            return false;
        }
    }

    private static void ScheduleDetachedCleanup()
    {
        try
        {
            MoveFileEx(
                GetCurrentExecutablePath(),
                null,
                MoveFileDelayUntilReboot
            );
        }
        catch { }
    }

    private static void CleanupStaleDetachedCopies()
    {
        try
        {
            string current = Path.GetFullPath(GetCurrentExecutablePath());
            string pattern = DetachedPrefix + "*.exe";

            foreach (string file in Directory.GetFiles(Path.GetTempPath(), pattern))
            {
                try
                {
                    if (String.Equals(
                        Path.GetFullPath(file),
                        current,
                        StringComparison.OrdinalIgnoreCase
                    ))
                    {
                        continue;
                    }

                    File.Delete(file);
                }
                catch { }
            }
        }
        catch { }
    }

    private static int RunInstallerSelfTest()
    {
        string root = Path.Combine(
            Path.GetTempPath(),
            "TailscaleQuickRepair-Setup-SelfTest-" + Guid.NewGuid().ToString("N")
        );
        string appDir = Path.Combine(root, "app");
        string installedSetup = Path.Combine(appDir, "TailscaleQuickRepairSetup.exe");
        string marker = Path.Combine(root, "relocation-ok.txt");

        try
        {
            Directory.CreateDirectory(appDir);
            File.Copy(GetCurrentExecutablePath(), installedSetup, true);

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = installedSetup;
            psi.Arguments = JoinArguments(new string[]
            {
                "--self-test-relocation-parent",
                "--marker",
                marker
            });
            psi.WorkingDirectory = appDir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.EnvironmentVariables[SelfTestAppDirEnvironment] = appDir;

            using (Process parent = Process.Start(psi))
            {
                if (parent == null)
                {
                    return 45;
                }

                if (!parent.WaitForExit(10000) || parent.ExitCode != 0)
                {
                    return 46;
                }
            }

            for (int i = 0; i < 150 && !File.Exists(marker); i++)
            {
                Thread.Sleep(100);
            }

            if (!File.Exists(marker))
            {
                return 47;
            }

            string replaced = File.ReadAllText(installedSetup);
            if (!String.Equals(replaced, "relocation-test-replaced", StringComparison.Ordinal))
            {
                return 48;
            }

            // Keep the host's original non-destructive self-test as part of the
            // same release gate after self-replacement has been proven.
            int hostResult = InvokeSetupHost(new string[] { "--self-test-installer" });
            if (hostResult != 0)
            {
                return 49;
            }

            return 0;
        }
        finally
        {
            Environment.SetEnvironmentVariable(SelfTestAppDirEnvironment, null);

            try
            {
                Thread.Sleep(250);
                if (Directory.Exists(root))
                {
                    Directory.Delete(root, true);
                }
            }
            catch { }

            CleanupStaleDetachedCopies();
        }
    }

    // Native acceptance test used by GitHub Actions. The parent executable is
    // staged at the installed Setup path. It launches a detached copy and
    // exits. The child then proves it can exclusively open, delete and replace
    // the original executable. This catches the Windows self-lock regression
    // that compile-only tests cannot detect.
    private static int RunRelocationSelfTestParent(string[] args)
    {
        string marker = ReadArg(args, "--marker");

        if (String.IsNullOrWhiteSpace(marker))
        {
            return 40;
        }

        if (!IsRunningFromInstalledSetup())
        {
            return 41;
        }

        string current = GetCurrentExecutablePath();

        return RelaunchDetached(new string[]
        {
            "--self-test-relocation-child",
            "--original",
            current,
            "--marker",
            marker
        });
    }

    private static int RunRelocationSelfTestChild(string[] args)
    {
        string original = ReadArg(args, "--original");
        string marker = ReadArg(args, "--marker");

        if (
            String.IsNullOrWhiteSpace(original) ||
            String.IsNullOrWhiteSpace(marker)
        )
        {
            return 42;
        }

        if (!IsDetachedSetupCopy())
        {
            return 43;
        }

        ScheduleDetachedCleanup();

        for (int attempt = 0; attempt < 100; attempt++)
        {
            try
            {
                using (FileStream probe = new FileStream(
                    original,
                    FileMode.Open,
                    FileAccess.ReadWrite,
                    FileShare.None
                ))
                {
                }

                File.Delete(original);
                File.WriteAllText(
                    original,
                    "relocation-test-replaced",
                    new UTF8Encoding(false)
                );

                File.WriteAllText(
                    marker,
                    GetCurrentExecutablePath(),
                    new UTF8Encoding(false)
                );

                return 0;
            }
            catch (IOException)
            {
                Thread.Sleep(100);
            }
            catch (UnauthorizedAccessException)
            {
                Thread.Sleep(100);
            }
        }

        return 44;
    }

    private static string ReadConfiguredPeer()
    {
        string path = Path.Combine(
            GetAppDir(),
            "config.json"
        );

        if (!File.Exists(path))
        {
            throw new InvalidDataException(
                "No target is configured. Open Quick Repair and choose a target first."
            );
        }

        Dictionary<string, object> config =
            Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(path));

        if (config == null || !config.ContainsKey("peer"))
        {
            throw new InvalidDataException("Quick Repair target configuration is invalid.");
        }

        string peer = Convert.ToString(config["peer"]);
        if (String.IsNullOrWhiteSpace(peer))
        {
            throw new InvalidDataException("Quick Repair target is empty.");
        }

        return peer.Trim();
    }

    private static bool IsStartupEnabled()
    {
        try
        {
            using (RegistryKey run = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Run"
            ))
            {
                object value = run == null ? null : run.GetValue("Tailscale Quick Repair");
                return value != null && !String.IsNullOrWhiteSpace(Convert.ToString(value));
            }
        }
        catch
        {
            return false;
        }
    }

    private static string GetCurrentExecutablePath()
    {
        using (Process process = Process.GetCurrentProcess())
        {
            if (process.MainModule == null)
            {
                throw new InvalidOperationException("Setup executable path is unavailable.");
            }

            return process.MainModule.FileName;
        }
    }

    private static string GetAppDir()
    {
        string selfTest = Environment.GetEnvironmentVariable(SelfTestAppDirEnvironment);

        if (!String.IsNullOrWhiteSpace(selfTest))
        {
            return Path.GetFullPath(selfTest);
        }

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "TailscaleQuickRepair"
        );
    }

    private static string ReadArg(string[] args, string name)
    {
        if (args == null)
        {
            return String.Empty;
        }

        for (int i = 0; i < args.Length - 1; i++)
        {
            if (String.Equals(args[i], name, StringComparison.OrdinalIgnoreCase))
            {
                return args[i + 1];
            }
        }

        return String.Empty;
    }

    private static string JoinArguments(string[] args)
    {
        StringBuilder value = new StringBuilder();

        if (args == null)
        {
            return String.Empty;
        }

        for (int i = 0; i < args.Length; i++)
        {
            if (i > 0)
            {
                value.Append(' ');
            }

            value.Append(Quote(args[i]));
        }

        return value.ToString();
    }

    private static string Quote(string value)
    {
        if (value == null)
        {
            return "\"\"";
        }

        return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }

    private static bool HasSwitch(string[] args, string name)
    {
        if (args == null) return false;

        foreach (string arg in args)
        {
            if (String.Equals(arg, name, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}
