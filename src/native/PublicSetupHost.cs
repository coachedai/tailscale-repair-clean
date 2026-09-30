using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: System.Reflection.AssemblyTitle("Tailscale Quick Repair Setup")]
[assembly: System.Reflection.AssemblyProduct("Tailscale Quick Repair")]
[assembly: System.Reflection.AssemblyVersion("3.0.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("3.0.0.0")]

internal static class PublicSetupHost
{
    private const string StableManifestApiUrl =
        "https://api.github.com/repos/coachedai/tailscale-repair-clean/contents/updates/latest.json?ref=main";
    private const string PreviewManifestApiUrl =
        "https://api.github.com/repos/coachedai/tailscale-repair-clean/contents/updates/preview.json?ref=preview";
    private const string StableManifestPath = "updates/latest.json";
    private const string PreviewManifestPath = "updates/preview.json";
    private const string TrustedHost = "github.com";
    private const string TrustedReleasePrefix = "/coachedai/tailscale-repair-clean/releases/download/";
    private const string RepairTaskName = "Tailscale Quick Repair";
    private const string AutoTaskName = "Tailscale Quick Repair Auto Monitor";
    private const string StartupName = "Tailscale Quick Repair";

    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();

    private static Tqr.OperationLease operationLease;

    private static bool TryAcquireOperationLock(string kind)
    {
        operationLease = Tqr.OperationGate.TryAcquire(
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "TailscaleQuickRepair"), kind);
        return operationLease != null;
    }

    private static void ReleaseOperationLock()
    {
        if (operationLease != null)
        {
            operationLease.Dispose();
            operationLease = null;
        }
    }

    private static bool TryAcquireUpgradeOperationLock()
    {
        string root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "TailscaleQuickRepair"
        );
        Stopwatch watch = Stopwatch.StartNew();

        while (watch.Elapsed < TimeSpan.FromSeconds(15))
        {
            if (TryAcquireOperationLock("setup")) return true;

            Tqr.OperationState owner = Tqr.OperationGate.Inspect(root);
            if (owner != null &&
                !String.Equals(owner.kind, "update", StringComparison.Ordinal) &&
                !String.Equals(owner.kind, "another operation", StringComparison.Ordinal))
                return false;

            System.Threading.Thread.Sleep(100);
        }

        return false;
    }

    [STAThread]
    private static int Main(string[] args)
    {
        bool operationAcquired = false;

        try
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;

            if (HasSwitch(args, "--self-test-installer"))
            {
                return RunInstallerSelfTest();
            }

            string requesterSid = ReadArg(args, "--requester-sid");
            RequireRequesterIdentity(requesterSid);

            bool repairOnly = HasSwitch(args, "--repair");
            bool upgradeOnly = HasSwitch(args, "--upgrade");
            string channel = NormalizeChannel(ReadArg(args, "--channel"));
            long targetCode = ReadLongArg(args, "--target-code", 0);

            if (repairOnly && upgradeOnly)
                throw new InvalidDataException("Setup mode is invalid.");

            string peer = ReadArg(args, "--peer");
            bool startup = !String.Equals(ReadArg(args, "--startup"), "false", StringComparison.OrdinalIgnoreCase);

            if ((repairOnly || upgradeOnly) && String.IsNullOrWhiteSpace(peer))
            {
                peer = ReadConfiguredPeer();
                startup = IsStartupEnabled();
            }

            if (!repairOnly && !upgradeOnly && String.IsNullOrWhiteSpace(peer))
            {
                SetupChoice choice = ShowSetupDialog();
                if (choice == null) return 0;
                peer = choice.Peer;
                startup = choice.StartWithWindows;
            }

            peer = NormalizePeer(peer);

            if (!IsAdministrator())
            {
                return RelaunchElevated(peer, startup, repairOnly, upgradeOnly, CurrentUserSid(), channel, targetCode);
            }

            bool acquired = upgradeOnly
                ? TryAcquireUpgradeOperationLock()
                : TryAcquireOperationLock(repairOnly ? "maintenance" : "setup");

            if (!acquired)
                throw new InvalidOperationException("Another Quick Repair operation is already running. Try Setup again when it finishes.");

            operationAcquired = true;

            return repairOnly
                ? RepairIntegration(peer, startup)
                : Install(peer, startup, upgradeOnly, channel, targetCode);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Setup could not complete.\r\n\r\n" + ex.Message,
                "Tailscale Quick Repair Setup",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error
            );
            return 10;
        }
        finally
        {
            if (operationAcquired) ReleaseOperationLock();
        }
    }

    private static int RunInstallerSelfTest()
    {
        foreach (string channel in new string[] { "stable", "preview" })
        {
            Uri uri;
            if (!Uri.TryCreate(GetManifestApiUrl(channel), UriKind.Absolute, out uri) ||
                !String.Equals(uri.Scheme, "https", StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(uri.Host, "api.github.com", StringComparison.OrdinalIgnoreCase))
            {
                return 2;
            }
        }

        try
        {
            NormalizeChannel("arbitrary-url");
            return 3;
        }
        catch (InvalidDataException) { }

        string root = Path.Combine(
            Path.GetTempPath(),
            "TailscaleQuickRepair-LauncherSelfTest-" + Guid.NewGuid().ToString("N")
        );

        try
        {
            Directory.CreateDirectory(root);

            string script = Path.Combine(root, "worker.ps1");
            string marker = Path.Combine(root, "marker.txt");
            string launcher = Path.Combine(root, "launcher.vbs");
            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\powershell.exe"
            );

            string escapedMarker = marker.Replace("'", "''");
            File.WriteAllText(
                script,
                "[IO.File]::WriteAllText('" + escapedMarker + "','ok')",
                new UTF8Encoding(false)
            );

            string command =
                "\"" + powershell + "\"" +
                " -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " +
                "\"" + script + "\"";

            string body = BuildHiddenLauncherBody(command);
            File.WriteAllText(launcher, body, new UTF8Encoding(false));

            string wscript = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\wscript.exe"
            );

            using (Process process = Process.Start(new ProcessStartInfo
            {
                FileName = wscript,
                Arguments = "\"" + launcher + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            }))
            {
                if (process == null || !process.WaitForExit(10000) || process.ExitCode != 0)
                {
                    return 3;
                }
            }

            if (!File.Exists(marker) || File.ReadAllText(marker) != "ok")
            {
                return 4;
            }

            return 0;
        }
        finally
        {
            try
            {
                if (Directory.Exists(root))
                {
                    Directory.Delete(root, true);
                }
            }
            catch { }
        }
    }
    private static int Install(string peer, bool startup, bool upgradeOnly, string channel, long targetCode)
    {
        // Restore any payload transaction that was interrupted by a killed
        // Setup process before downloading or applying another release.
        RecoverInterruptedFileTransaction();

        string work = Path.Combine(Path.GetTempPath(), "TailscaleQuickRepair-Setup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);

        try
        {
            SetupManifest manifest = FetchSetupManifest(channel, targetCode);
            string zip = Path.Combine(work, "setup.zip");
            DownloadFile(manifest.Url, zip);

            FileInfo file = new FileInfo(zip);
            if (file.Length != manifest.Size)
                throw new InvalidDataException("Setup package size did not match the trusted manifest.");

            if (!String.Equals(Sha256File(zip), manifest.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Setup package failed SHA-256 verification.");

            string extract = Path.Combine(work, "package");
            Directory.CreateDirectory(extract);
            ZipFile.ExtractToDirectory(zip, extract);

            PackageManifest package = ReadPackageManifest(extract);
            if (package.VersionCode != manifest.VersionCode || !String.Equals(package.Version, manifest.Version, StringComparison.Ordinal))
                throw new InvalidDataException("Setup package metadata does not match the trusted channel.");

            List<InstallFile> files = VerifyPackage(extract, package);
            ValidateProtectedUpdateMarker(package.VersionCode, channel);

            StopQuickRepair();
            ApplyFiles(files, work);
            CompleteInstalledIntegration(peer, startup, upgradeOnly, package.VersionCode);
            StartQuickRepair();

            MessageBox.Show(
                "Tailscale Quick Repair is ready.\r\n\r\nTarget: " + peer,
                "Tailscale Quick Repair Setup",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information
            );

            return 0;
        }
        finally
        {
            try { if (Directory.Exists(work)) Directory.Delete(work, true); } catch { }
        }
    }

    private static void CompleteInstalledIntegration(string peer, bool startup, bool upgradeOnly, long versionCode)
    {
        CompleteInstalledIntegrationCore(peer, startup, upgradeOnly, versionCode, null);
    }

    // Production uses the wrapper above. The callback is a private acceptance
    // seam that lets the disposable Windows lab kill Setup at a known completed
    // integration step, then prove the next process can safely replay the same
    // fixed sequence to completion.
    private static void CompleteInstalledIntegrationCore(
        string peer,
        bool startup,
        bool upgradeOnly,
        long versionCode,
        Action<int> afterStep)
    {
        int step = 0;

        WriteLocalConfig(peer);
        if (afterStep != null) afterStep(++step); else step++;

        RegisterRepairTask();
        if (afterStep != null) afterStep(++step); else step++;

        RegisterAutoRepairTask();
        if (afterStep != null) afterStep(++step); else step++;

        ConfigureStartup(startup);
        if (afterStep != null) afterStep(++step); else step++;

        CreateStartMenuShortcut();
        if (afterStep != null) afterStep(++step); else step++;

        if (upgradeOnly)
        {
            WriteRestartPending(versionCode);
            if (afterStep != null) afterStep(++step); else step++;
        }

        RemoveProtectedUpdateMarker();
        if (afterStep != null) afterStep(++step);
    }

    private static int RepairIntegration(string peer, bool startup)
    {
        RequireInstalledFile(Path.Combine(GetAppDir(), "TailscaleQuickRepair.exe"));
        RequireInstalledFile(Path.Combine(GetAppDir(), "Tailscale-Repair-UI.ps1"));
        RequireInstalledFile(Path.Combine(GetProgramDir(), "Repair-Backend.ps1"));
        RequireInstalledFile(Path.Combine(GetProgramDir(), "Auto-Repair-Monitor.ps1"));

        WriteLocalConfig(peer);
        RegisterRepairTask();
        RegisterAutoRepairTask();
        ConfigureStartup(startup);
        CreateStartMenuShortcut();

        MessageBox.Show(
            "Quick Repair's Windows integration was rebuilt successfully.",
            "Tailscale Quick Repair Setup",
            MessageBoxButtons.OK,
            MessageBoxIcon.Information
        );

        StartQuickRepair();
        return 0;
    }

    internal static string NormalizeChannel(string value)
    {
        if (String.IsNullOrWhiteSpace(value) ||
            String.Equals(value, "stable", StringComparison.OrdinalIgnoreCase))
            return "stable";

        if (String.Equals(value, "preview", StringComparison.OrdinalIgnoreCase))
            return "preview";

        throw new InvalidDataException("Unsupported Quick Repair update channel.");
    }

    internal static string GetManifestApiUrl(string channel)
    {
        return NormalizeChannel(channel) == "preview"
            ? PreviewManifestApiUrl
            : StableManifestApiUrl;
    }

    private static string GetExpectedManifestPath(string channel)
    {
        return NormalizeChannel(channel) == "preview"
            ? PreviewManifestPath
            : StableManifestPath;
    }

    private static SetupManifest FetchSetupManifest(string channel, long targetCode)
    {
        channel = NormalizeChannel(channel);
        string apiJson = DownloadString(GetManifestApiUrl(channel), true);
        Dictionary<string, object> api = Deserialize(apiJson);
        string encoding = ReadString(api, "encoding");
        string apiPath = ReadString(api, "path");
        string content = ReadString(api, "content").Replace("\r", "").Replace("\n", "");

        if (!String.Equals(encoding, "base64", StringComparison.OrdinalIgnoreCase) ||
            !String.Equals(apiPath, GetExpectedManifestPath(channel), StringComparison.Ordinal) ||
            String.IsNullOrWhiteSpace(content))
            throw new InvalidDataException("GitHub returned an unexpected setup-channel response.");

        Dictionary<string, object> root = Deserialize(Encoding.UTF8.GetString(Convert.FromBase64String(content)));
        if (ReadInt(root, "schema") != 1 || !ReadBool(root, "published"))
            throw new InvalidDataException("No installable Quick Repair release is currently published.");
        if (channel == "preview" && !String.Equals(ReadString(root, "channel"), "preview", StringComparison.Ordinal))
            throw new InvalidDataException("The Early-access setup manifest channel is invalid.");

        Dictionary<string, object> setup = ReadDictionary(root, "setup");
        SetupManifest result = new SetupManifest();
        result.Version = ReadString(root, "version");
        result.VersionCode = ReadLong(root, "versionCode");
        result.Url = ReadString(setup, "url");
        result.Sha256 = ReadString(setup, "sha256").ToLowerInvariant();
        result.Size = ReadLong(setup, "size");

        if (targetCode > 0 && result.VersionCode != targetCode)
            throw new InvalidDataException("The selected setup release changed. Check for updates again.");

        if (String.IsNullOrWhiteSpace(result.Version) || result.VersionCode <= 0 || result.Size <= 0 ||
            !IsSha256(result.Sha256) || !IsTrustedReleaseUrl(result.Url))
            throw new InvalidDataException("The setup manifest failed trust validation.");

        return result;
    }
    private static PackageManifest ReadPackageManifest(string root)
    {
        string path = Path.Combine(root, "package-manifest.json");
        if (!File.Exists(path)) throw new InvalidDataException("Setup package is missing package-manifest.json.");

        Dictionary<string, object> data = Deserialize(File.ReadAllText(path, Encoding.UTF8));
        if (ReadInt(data, "schema") != 1) throw new InvalidDataException("Unsupported setup package schema.");

        PackageManifest manifest = new PackageManifest();
        manifest.Version = ReadString(data, "version");
        manifest.VersionCode = ReadLong(data, "versionCode");
        manifest.Files = new List<PackageFile>();

        object raw;
        if (!data.TryGetValue("files", out raw)) throw new InvalidDataException("Setup package contains no file list.");

        object[] array = raw as object[];
        if (array == null)
        {
            ArrayList list = raw as ArrayList;
            if (list != null) array = list.ToArray();
        }
        if (array == null) throw new InvalidDataException("Setup package file list is invalid.");

        foreach (object item in array)
        {
            Dictionary<string, object> entry = item as Dictionary<string, object>;
            if (entry == null) throw new InvalidDataException("Setup package contains an invalid file entry.");

            PackageFile packageFile = new PackageFile();
            packageFile.Path = ReadString(entry, "path");
            packageFile.Sha256 = ReadString(entry, "sha256").ToLowerInvariant();
            packageFile.Size = ReadLong(entry, "size");

            if (String.IsNullOrWhiteSpace(packageFile.Path) || packageFile.Size < 0 || !IsSha256(packageFile.Sha256))
                throw new InvalidDataException("Setup package contains invalid file metadata.");

            manifest.Files.Add(packageFile);
        }

        return manifest;
    }

    private static List<InstallFile> VerifyPackage(string extractRoot, PackageManifest package)
    {
        string trustedRoot = EnsureTrailingSeparator(Path.GetFullPath(extractRoot));
        List<InstallFile> verified = new List<InstallFile>();

        foreach (PackageFile file in package.Files)
        {
            string relative = file.Path.Replace('/', Path.DirectorySeparatorChar);
            string source = Path.GetFullPath(Path.Combine(extractRoot, relative));

            if (!source.StartsWith(trustedRoot, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Setup package path escapes staging: " + file.Path);
            if (!File.Exists(source)) throw new InvalidDataException("Setup package file is missing: " + file.Path);

            FileInfo info = new FileInfo(source);
            if (info.Length != file.Size || !String.Equals(Sha256File(source), file.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Setup package verification failed: " + file.Path);

            verified.Add(new InstallFile {
                Source = source,
                Target = ResolveInstallTarget(file.Path),
                RelativePath = file.Path,
                Sha256 = file.Sha256
            });
        }

        RequirePackageFile(verified, "app/TailscaleQuickRepair.exe");
        RequirePackageFile(verified, "app/Tailscale-Repair-UI.ps1");
        RequirePackageFile(verified, "app/TailscaleQuickRepairUpdater.exe");
        RequirePackageFile(verified, "app/TailscaleQuickRepairSetup.exe");
        RequirePackageFile(verified, "app/Advanced-Diagnostics.ps1");
        RequirePackageFile(verified, "program/Repair-Backend.ps1");
        RequirePackageFile(verified, "program/Auto-Repair-Monitor.ps1");
        return verified;
    }

    private static string ResolveInstallTarget(string relativePath)
    {
        string normalized = relativePath.Replace('\\', '/');
        if (String.Equals(normalized, "version.json", StringComparison.OrdinalIgnoreCase))
            return Path.Combine(GetAppDir(), "version.user.json");
        if (normalized.StartsWith("app/", StringComparison.OrdinalIgnoreCase))
            return ResolveUnder(GetAppDir(), normalized.Substring(4));
        if (normalized.StartsWith("program/", StringComparison.OrdinalIgnoreCase))
            return ResolveUnder(GetProgramDir(), normalized.Substring(8));
        throw new InvalidDataException("Unsupported setup package path: " + relativePath);
    }

    private static string ResolveUnder(string root, string relative)
    {
        string trusted = EnsureTrailingSeparator(Path.GetFullPath(root));
        string target = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
        if (!target.StartsWith(trusted, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Setup target path escapes its install root.");
        return target;
    }

    private const int RecoverySchema = 1;
    private const int RecoveryByteLimit = 32768;
    private const int RecoveryEntryLimit = 64;
    private const string RecoveryJournalName = "transaction.json";
    private const string RecoveryNextName = "transaction.next";

    private static void ApplyFiles(List<InstallFile> files, string work)
    {
        ApplyFilesCore(files, work, null);
    }

    // afterReplace is a private acceptance seam only. Production always passes
    // null; the disposable Windows lab uses it to suspend a real transaction
    // after a replacement so the owning process can be killed.
    private static void ApplyFilesCore(List<InstallFile> files, string work, Action<int> afterReplace)
    {
        RecoverInterruptedFileTransaction();
        MigrateKnownLegacyProtectedLayout();
        PrepareProtectedRoot();

        RecoveryDocument transaction = null;
        try
        {
            transaction = PrepareFileTransaction(files);

            int applied = 0;
            foreach (InstallFile file in files)
            {
                string parent = Path.GetDirectoryName(file.Target);
                if (!String.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);

                string next = file.Target + ".setup.new";
                if (File.Exists(next) || Directory.Exists(next))
                    throw new IOException("Setup temporary path already exists. Existing evidence was preserved.");
                CheckInstallPath(next);
                CopyFileFlushed(file.Source, next, false);

                if (Directory.Exists(file.Target))
                    throw new IOException("Setup target unexpectedly became a directory.");
                CheckInstallPath(file.Target);
                if (File.Exists(file.Target)) File.Delete(file.Target);
                File.Move(next, file.Target);
                ProtectInstalledProgramFile(file.Target);

                applied++;
                if (afterReplace != null) afterReplace(applied);
            }

            foreach (InstallFile file in files)
            {
                if (!File.Exists(file.Target) ||
                    !String.Equals(Sha256File(file.Target), file.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Installed file verification failed: " + file.RelativePath);
            }

            CompleteFileTransaction(transaction, afterReplace);
            transaction = null;
        }
        catch
        {
            if (transaction != null)
            {
                try
                {
                    RecoverInterruptedFileTransaction();
                    transaction = null;
                }
                catch (Exception recovery)
                {
                    throw new IOException(
                        "Setup stopped after a file error and the previous files could not be fully restored. " +
                        "Recovery evidence was preserved.",
                        recovery
                    );
                }
            }
            throw;
        }
    }

    private static string GetRecoveryRoot()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "TailscaleQuickRepair.SetupRecovery"
        );
    }

    private static System.Security.AccessControl.DirectorySecurity RecoveryDirectorySecurity()
    {
        var security = new System.Security.AccessControl.DirectorySecurity();
        security.SetSecurityDescriptorSddlForm(
            "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
        );
        return security;
    }

    private static void RequireRecoveryRootSecurity(string root)
    {
        if (!Directory.Exists(root) || File.Exists(root))
            throw new IOException("Setup recovery storage has an unexpected type.");

        CheckInstallPath(root);
        var actual = Directory.GetAccessControl(root);
        if (!actual.AreAccessRulesProtected ||
            actual.GetOwner(typeof(SecurityIdentifier)).Value != "S-1-5-32-544")
            throw new IOException("Setup recovery storage permissions are invalid.");

        bool system = false;
        bool admins = false;
        var rules = actual.GetAccessRules(true, true, typeof(SecurityIdentifier));
        foreach (System.Security.AccessControl.AuthorizationRule raw in rules)
        {
            var rule = raw as System.Security.AccessControl.FileSystemAccessRule;
            if (rule == null ||
                rule.AccessControlType != System.Security.AccessControl.AccessControlType.Allow)
                throw new IOException("Setup recovery storage permissions are invalid.");

            string sid = rule.IdentityReference.Value;
            if (sid == "S-1-5-18") system = true;
            else if (sid == "S-1-5-32-544") admins = true;
            else throw new IOException("Setup recovery storage grants an unexpected identity.");
        }

        if (!system || !admins)
            throw new IOException("Setup recovery storage permissions are incomplete.");
    }

    private static string EnsureRecoveryRoot()
    {
        string root = GetRecoveryRoot();
        CheckInstallPath(root);

        if (File.Exists(root))
            throw new IOException("Setup recovery storage is occupied by a file.");

        if (!Directory.Exists(root))
            Directory.CreateDirectory(root, RecoveryDirectorySecurity());

        RequireRecoveryRootSecurity(root);
        return root;
    }

    private static void RefuseUnsafeTemporaryPath(string path)
    {
        if (Directory.Exists(path))
            throw new IOException("Setup temporary path is occupied by a directory.");
        if (File.Exists(path))
        {
            FileAttributes attributes = File.GetAttributes(path);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Setup temporary path is redirected.");
            using (FileStream probe = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                RequireSingleLink(probe);
            File.Delete(path);
        }
    }

    private static void CopyFileFlushed(string source, string destination, bool replaceDestination)
    {
        if (replaceDestination) RefuseUnsafeTemporaryPath(destination);
        else if (File.Exists(destination) || Directory.Exists(destination))
            throw new IOException("Setup recovery backup already exists.");

        using (FileStream input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (FileStream output = new FileStream(
            destination,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            65536,
            FileOptions.WriteThrough))
        {
            input.CopyTo(output);
            output.Flush(true);
        }
    }

    private static RecoveryDocument PrepareFileTransaction(List<InstallFile> files)
    {
        if (files == null || files.Count == 0 || files.Count > RecoveryEntryLimit)
            throw new InvalidDataException("Setup transaction file count is invalid.");

        string root = EnsureRecoveryRoot();
        string journal = Path.Combine(root, RecoveryJournalName);
        if (File.Exists(journal) || Directory.Exists(journal))
            throw new IOException("An earlier Setup transaction still needs recovery.");

        HashSet<string> paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        List<RecoveryEntry> entries = new List<RecoveryEntry>();
        int number = 0;

        foreach (InstallFile file in files)
        {
            string relative = file.RelativePath.Replace('\\', '/');
            if (!paths.Add(relative))
                throw new InvalidDataException("Setup transaction contains a duplicate path.");

            // Resolve through the same fixed target mapper used by installation.
            string target = ResolveInstallTarget(relative);
            if (!String.Equals(Path.GetFullPath(target), Path.GetFullPath(file.Target), StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Setup transaction target changed unexpectedly.");
            if (Directory.Exists(target))
                throw new IOException("Setup target is unexpectedly a directory.");

            bool existed = File.Exists(target);
            if (existed)
            {
                CheckInstallPath(target);
                using (FileStream probe = new FileStream(target, FileMode.Open, FileAccess.Read, FileShare.Read))
                    RequireSingleLink(probe);
            }

            number++;
            entries.Add(new RecoveryEntry {
                path = relative,
                existed = existed,
                backup = existed ? number.ToString("D4", CultureInfo.InvariantCulture) + ".bak" : "",
                sha256 = "",
                size = 0,
                newSha256 = file.Sha256.ToLowerInvariant()
            });
        }

        RecoveryDocument document = new RecoveryDocument {
            schema = RecoverySchema,
            state = "preparing",
            userSid = CurrentUserSid(),
            entries = entries.ToArray()
        };
        WriteRecoveryDocument(root, document);

        try
        {
            foreach (RecoveryEntry entry in document.entries)
            {
                if (!entry.existed) continue;
                string target = ResolveInstallTarget(entry.path);
                string backup = Path.Combine(root, entry.backup);
                CopyFileFlushed(target, backup, false);
                FileInfo info = new FileInfo(backup);
                entry.size = info.Length;
                entry.sha256 = Sha256File(backup);
            }

            document.state = "prepared";
            WriteRecoveryDocument(root, document);
            ValidatePreparedRecovery(root, document);
            return document;
        }
        catch
        {
            // No product file is mutated before the prepared journal is durable.
            try { CleanupPreparingRecovery(root); } catch { }
            throw;
        }
    }

    private static void WriteRecoveryDocument(string root, RecoveryDocument document)
    {
        RequireRecoveryRootSecurity(root);
        byte[] bytes = new UTF8Encoding(false, true).GetBytes(Json.Serialize(document));
        if (bytes.Length < 2 || bytes.Length > RecoveryByteLimit)
            throw new InvalidDataException("Setup recovery journal is too large.");

        string journal = Path.Combine(root, RecoveryJournalName);
        string next = Path.Combine(root, RecoveryNextName);
        RefuseUnsafeTemporaryPath(next);

        using (FileStream stream = new FileStream(
            next, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
        {
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush(true);
        }

        if (File.Exists(journal)) File.Replace(next, journal, null);
        else File.Move(next, journal);
    }

    private static RecoveryDocument ReadRecoveryDocument(string root)
    {
        RequireRecoveryRootSecurity(root);
        string journal = Path.Combine(root, RecoveryJournalName);
        if (!File.Exists(journal) || Directory.Exists(journal))
            throw new FileNotFoundException("Setup recovery journal is missing.", journal);

        CheckInstallPath(journal);
        using (FileStream probe = new FileStream(journal, FileMode.Open, FileAccess.Read, FileShare.Read))
            RequireSingleLink(probe);

        FileInfo info = new FileInfo(journal);
        if (info.Length < 2 || info.Length > RecoveryByteLimit)
            throw new InvalidDataException("Setup recovery journal size is invalid.");

        Dictionary<string, object> rootFields =
            Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(journal, new UTF8Encoding(false, true)));
        if (rootFields == null || rootFields.Count != 4 ||
            !rootFields.ContainsKey("schema") || !rootFields.ContainsKey("state") ||
            !rootFields.ContainsKey("userSid") || !rootFields.ContainsKey("entries") ||
            !(rootFields["schema"] is int) || Convert.ToInt32(rootFields["schema"]) != RecoverySchema ||
            !(rootFields["state"] is string) || !(rootFields["userSid"] is string))
            throw new InvalidDataException("Setup recovery journal schema is invalid.");

        string state = Convert.ToString(rootFields["state"]);
        if (state != "preparing" && state != "prepared" && state != "committed" && state != "rolledBack")
            throw new InvalidDataException("Setup recovery journal state is invalid.");
        string userSid = NormalizeSid(Convert.ToString(rootFields["userSid"]));

        object[] rawEntries = rootFields["entries"] as object[];
        if (rawEntries == null)
        {
            ArrayList list = rootFields["entries"] as ArrayList;
            if (list != null) rawEntries = list.ToArray();
        }
        if (rawEntries == null || rawEntries.Length == 0 || rawEntries.Length > RecoveryEntryLimit)
            throw new InvalidDataException("Setup recovery journal entry count is invalid.");

        HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        List<RecoveryEntry> entries = new List<RecoveryEntry>();
        foreach (object raw in rawEntries)
        {
            Dictionary<string, object> fields = raw as Dictionary<string, object>;
            if (fields == null || fields.Count != 6 ||
                !fields.ContainsKey("path") || !fields.ContainsKey("existed") ||
                !fields.ContainsKey("backup") || !fields.ContainsKey("sha256") || !fields.ContainsKey("size") ||
                !fields.ContainsKey("newSha256") ||
                !(fields["path"] is string) || !(fields["existed"] is bool) ||
                !(fields["backup"] is string) || !(fields["sha256"] is string) ||
                !(fields["newSha256"] is string) ||
                (!(fields["size"] is int) && !(fields["size"] is long)))
                throw new InvalidDataException("Setup recovery journal entry is invalid.");

            RecoveryEntry entry = new RecoveryEntry {
                path = Convert.ToString(fields["path"]).Replace('\\', '/'),
                existed = Convert.ToBoolean(fields["existed"]),
                backup = Convert.ToString(fields["backup"]),
                sha256 = Convert.ToString(fields["sha256"]).ToLowerInvariant(),
                size = Convert.ToInt64(fields["size"]),
                newSha256 = Convert.ToString(fields["newSha256"]).ToLowerInvariant()
            };

            if (!seen.Add(entry.path))
                throw new InvalidDataException("Setup recovery journal contains a duplicate path.");
            ResolveInstallTarget(entry.path);
            if (!IsSha256(entry.newSha256))
                throw new InvalidDataException("Setup recovery candidate digest is invalid.");

            if (entry.existed)
            {
                if (!Regex.IsMatch(entry.backup, "^[0-9]{4}\\.bak$", RegexOptions.CultureInvariant))
                    throw new InvalidDataException("Setup recovery backup name is invalid.");
                if ((state == "prepared" || state == "committed" || state == "rolledBack") && (!IsSha256(entry.sha256) || entry.size < 0))
                    throw new InvalidDataException("Setup recovery backup metadata is invalid.");
            }
            else if (entry.backup.Length != 0 || entry.sha256.Length != 0 || entry.size != 0)
                throw new InvalidDataException("Setup recovery metadata for a new file is invalid.");

            entries.Add(entry);
        }

        return new RecoveryDocument { schema = RecoverySchema, state = state, userSid = userSid, entries = entries.ToArray() };
    }

    private static void ValidatePreparedRecovery(string root, RecoveryDocument document)
    {
        if (document == null || document.state != "prepared")
            throw new InvalidDataException("Setup recovery transaction is not prepared.");

        HashSet<string> expected = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        expected.Add(RecoveryJournalName);
        expected.Add(RecoveryNextName);

        foreach (RecoveryEntry entry in document.entries)
        {
            if (!entry.existed) continue;
            expected.Add(entry.backup);
            string backup = Path.Combine(root, entry.backup);
            if (!File.Exists(backup) || Directory.Exists(backup))
                throw new InvalidDataException("Setup recovery backup is missing.");
            CheckInstallPath(backup);
            using (FileStream probe = new FileStream(backup, FileMode.Open, FileAccess.Read, FileShare.Read))
                RequireSingleLink(probe);
            FileInfo info = new FileInfo(backup);
            if (info.Length != entry.size ||
                !String.Equals(Sha256File(backup), entry.sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Setup recovery backup verification failed.");
        }

        foreach (string item in Directory.GetFileSystemEntries(root))
        {
            string name = Path.GetFileName(item);
            if (!expected.Contains(name))
                throw new IOException("Setup recovery storage contains unexpected evidence.");
            if (Directory.Exists(item))
                throw new IOException("Setup recovery storage contains an unexpected directory.");
        }
    }

    private static void RequireRecoveryOwner(RecoveryDocument document)
    {
        if (document == null || String.IsNullOrWhiteSpace(document.userSid))
            throw new InvalidDataException("Setup recovery owner is missing.");

        string expected = NormalizeSid(document.userSid);
        if (!String.Equals(CurrentUserSid(), expected, StringComparison.Ordinal))
            throw new UnauthorizedAccessException(
                "Interrupted Setup recovery belongs to another Windows account. Existing recovery evidence was preserved."
            );
    }

    private static bool RecoverInterruptedFileTransaction()
    {
        return RecoverInterruptedFileTransactionCore(null);
    }

    // Private acceptance seam for kill/restart recovery tests. Production uses
    // the wrapper above and never supplies a callback.
    private static bool RecoverInterruptedFileTransactionCore(Action<int> afterRestore)
    {
        string root = GetRecoveryRoot();
        if (!Directory.Exists(root))
        {
            if (File.Exists(root))
                throw new IOException("Setup recovery storage is occupied by a file.");
            return false;
        }

        RequireRecoveryRootSecurity(root);
        string journal = Path.Combine(root, RecoveryJournalName);
        string next = Path.Combine(root, RecoveryNextName);

        if (!File.Exists(journal))
        {
            // A preparing transaction cannot have changed product files. Only
            // remove our fixed preparation artifacts; unexpected evidence fails closed.
            CleanupPreparingRecovery(root);
            return true;
        }

        RecoveryDocument document = ReadRecoveryDocument(root);
        RequireRecoveryOwner(document);
        if (document.state == "preparing")
        {
            CleanupPreparingRecovery(root);
            return true;
        }
        if (document.state == "committed")
        {
            CleanupCommittedRecovery(root, document, afterRestore);
            return true;
        }
        if (document.state == "rolledBack")
        {
            CleanupRolledBackRecovery(root, document, afterRestore);
            return true;
        }

        ValidatePreparedRecovery(root, document);

        // Validate every backup before modifying any target.
        foreach (RecoveryEntry entry in document.entries)
        {
            if (!entry.existed) continue;
            string backup = Path.Combine(root, entry.backup);
            FileInfo info = new FileInfo(backup);
            if (info.Length != entry.size ||
                !String.Equals(Sha256File(backup), entry.sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Setup recovery backup verification failed.");
        }

        int restored = 0;
        foreach (RecoveryEntry entry in document.entries)
        {
            string target = ResolveInstallTarget(entry.path);
            string setupTemp = target + ".setup.new";
            if (File.Exists(setupTemp))
            {
                CheckInstallPath(setupTemp);
                if ((File.GetAttributes(setupTemp) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Setup temporary recovery path is redirected.");
                File.Delete(setupTemp);
            }
            else if (Directory.Exists(setupTemp))
                throw new IOException("Setup temporary recovery path is a directory.");

            if (entry.existed)
            {
                string restoreTemp = target + ".setup.recover";
                RefuseUnsafeTemporaryPath(restoreTemp);
                CopyFileFlushed(Path.Combine(root, entry.backup), restoreTemp, true);

                if (Directory.Exists(target))
                    throw new IOException("Setup recovery target became a directory.");
                CheckInstallPath(target);
                if (File.Exists(target)) File.Delete(target);
                File.Move(restoreTemp, target);
                ProtectInstalledProgramFile(target);
            }
            else
            {
                if (Directory.Exists(target))
                    throw new IOException("Setup recovery target became a directory.");
                CheckInstallPath(target);
                if (File.Exists(target))
                {
                    if ((File.GetAttributes(target) & FileAttributes.ReparsePoint) != 0)
                        throw new IOException("Setup recovery target is redirected.");
                    File.Delete(target);
                }
            }

            restored++;
            if (afterRestore != null) afterRestore(restored);
        }

        foreach (RecoveryEntry entry in document.entries)
        {
            string target = ResolveInstallTarget(entry.path);
            if (entry.existed)
            {
                if (!File.Exists(target) ||
                    !String.Equals(Sha256File(target), entry.sha256, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Recovered Setup file verification failed.");
            }
            else if (File.Exists(target) || Directory.Exists(target))
                throw new IOException("A file created by the interrupted Setup could not be removed.");
        }

        CompleteRolledBackFileTransaction(document, afterRestore);
        return true;
    }

    private static void CleanupPreparingRecovery(string root)
    {
        RequireRecoveryRootSecurity(root);
        foreach (string item in Directory.GetFileSystemEntries(root))
        {
            string name = Path.GetFileName(item);
            if (name != RecoveryJournalName && name != RecoveryNextName &&
                !Regex.IsMatch(name, "^[0-9]{4}\\.bak$", RegexOptions.CultureInvariant))
                throw new IOException("Setup recovery storage contains unexpected evidence.");
            if (Directory.Exists(item))
                throw new IOException("Setup recovery storage contains an unexpected directory.");
        }

        foreach (string item in Directory.GetFiles(root))
        {
            CheckInstallPath(item);
            if ((File.GetAttributes(item) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Setup recovery evidence is redirected.");
            File.Delete(item);
        }
        Directory.Delete(root, false);
    }

    private static void CompleteRolledBackFileTransaction(RecoveryDocument document, Action<int> progress)
    {
        string root = GetRecoveryRoot();
        if (document == null || !Directory.Exists(root))
            throw new IOException("Setup recovery transaction disappeared.");

        RecoveryDocument current = ReadRecoveryDocument(root);
        RequireRecoveryOwner(current);
        if (!String.Equals(current.userSid, document.userSid, StringComparison.Ordinal) ||
            current.state != "prepared" || current.entries.Length != document.entries.Length)
            throw new InvalidDataException("Setup recovery transaction changed unexpectedly.");

        ValidatePreparedRecovery(root, current);
        ValidateRolledBackTargets(current);

        // Make the restored old file set durable before deleting any backup.
        // A kill during cleanup can therefore resume without depending on a
        // backup that a previous cleanup attempt already removed.
        current.state = "rolledBack";
        WriteRecoveryDocument(root, current);
        if (progress != null) progress(-1);
        CleanupRolledBackRecovery(root, current, progress);
    }

    private static void ValidateRolledBackTargets(RecoveryDocument document)
    {
        foreach (RecoveryEntry entry in document.entries)
        {
            string target = ResolveInstallTarget(entry.path);
            if (entry.existed)
            {
                if (!File.Exists(target) || Directory.Exists(target) ||
                    !String.Equals(Sha256File(target), entry.sha256, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Rolled-back Setup file verification failed.");
            }
            else if (File.Exists(target) || Directory.Exists(target))
                throw new IOException("A candidate-only file remains after Setup rollback.");
        }
    }

    private static void CleanupRolledBackRecovery(string root, RecoveryDocument document, Action<int> progress)
    {
        if (document == null || document.state != "rolledBack")
            throw new InvalidDataException("Setup recovery transaction is not rolled back.");

        RequireRecoveryOwner(document);
        RequireRecoveryRootSecurity(root);
        ValidateRolledBackTargets(document);

        HashSet<string> expected = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        expected.Add(RecoveryJournalName);
        expected.Add(RecoveryNextName);
        foreach (RecoveryEntry entry in document.entries)
            if (entry.existed) expected.Add(entry.backup);

        foreach (string item in Directory.GetFileSystemEntries(root))
        {
            string name = Path.GetFileName(item);
            if (!expected.Contains(name) || Directory.Exists(item))
                throw new IOException("Rolled-back Setup recovery storage contains unexpected evidence.");
        }

        int deletedBackups = 0;
        foreach (RecoveryEntry entry in document.entries)
        {
            if (!entry.existed) continue;
            string backup = Path.Combine(root, entry.backup);
            if (!File.Exists(backup)) continue;
            CheckInstallPath(backup);
            if ((File.GetAttributes(backup) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Rolled-back Setup backup is redirected.");
            File.Delete(backup);
            deletedBackups++;
            if (progress != null) progress(-1000 - deletedBackups);
        }

        string next = Path.Combine(root, RecoveryNextName);
        if (File.Exists(next))
        {
            CheckInstallPath(next);
            if ((File.GetAttributes(next) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Rolled-back Setup journal temporary file is redirected.");
            File.Delete(next);
        }

        File.Delete(Path.Combine(root, RecoveryJournalName));
        Directory.Delete(root, false);
    }

    private static void CompleteFileTransaction(RecoveryDocument document, Action<int> progress)
    {
        string root = GetRecoveryRoot();
        if (document == null || !Directory.Exists(root))
            throw new IOException("Setup recovery transaction disappeared.");

        RecoveryDocument current = ReadRecoveryDocument(root);
        RequireRecoveryOwner(current);
        if (!String.Equals(current.userSid, document.userSid, StringComparison.Ordinal) ||
            current.state != "prepared" || current.entries.Length != document.entries.Length)
            throw new InvalidDataException("Setup recovery transaction changed unexpectedly.");

        ValidatePreparedRecovery(root, current);
        foreach (RecoveryEntry entry in current.entries)
        {
            string target = ResolveInstallTarget(entry.path);
            if (!File.Exists(target) ||
                !String.Equals(Sha256File(target), entry.newSha256, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Installed file changed before transaction commit.");
        }

        // Commit the verified new file set before deleting any backup. If Setup
        // dies during cleanup, the next run can validate the new hashes and
        // finish cleanup instead of requiring a backup that was already removed.
        current.state = "committed";
        WriteRecoveryDocument(root, current);
        if (progress != null) progress(-2);
        CleanupCommittedRecovery(root, current, progress);
    }

    private static void CleanupCommittedRecovery(string root, RecoveryDocument document, Action<int> progress)
    {
        if (document == null || document.state != "committed")
            throw new InvalidDataException("Setup recovery transaction is not committed.");

        RequireRecoveryOwner(document);
        RequireRecoveryRootSecurity(root);
        HashSet<string> expected = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        expected.Add(RecoveryJournalName);
        expected.Add(RecoveryNextName);

        foreach (RecoveryEntry entry in document.entries)
        {
            if (entry.existed) expected.Add(entry.backup);
            string target = ResolveInstallTarget(entry.path);
            if (!File.Exists(target) ||
                !String.Equals(Sha256File(target), entry.newSha256, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Committed Setup file verification failed.");
        }

        foreach (string item in Directory.GetFileSystemEntries(root))
        {
            string name = Path.GetFileName(item);
            if (!expected.Contains(name) || Directory.Exists(item))
                throw new IOException("Committed Setup recovery storage contains unexpected evidence.");
        }

        int deletedBackups = 0;
        foreach (RecoveryEntry entry in document.entries)
        {
            if (!entry.existed) continue;
            string backup = Path.Combine(root, entry.backup);
            if (File.Exists(backup))
            {
                CheckInstallPath(backup);
                if ((File.GetAttributes(backup) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Committed Setup backup is redirected.");
                File.Delete(backup);
                deletedBackups++;
                if (progress != null) progress(-2000 - deletedBackups);
            }
        }

        string next = Path.Combine(root, RecoveryNextName);
        if (File.Exists(next))
        {
            CheckInstallPath(next);
            if ((File.GetAttributes(next) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Committed Setup journal temporary file is redirected.");
            File.Delete(next);
        }

        File.Delete(Path.Combine(root, RecoveryJournalName));
        Directory.Delete(root, false);
    }

    private static void RegisterRepairTask()
    {
        string launcher = WriteHiddenLauncher(
            "Launch-Tailscale-Backend.vbs",
            Path.Combine(GetProgramDir(), "Repair-Backend.ps1")
        );
        RegisterTask(RepairTaskName, launcher, false);
    }

    private static void RegisterAutoRepairTask()
    {
        string launcher = WriteHiddenLauncher(
            "Launch-Auto-Repair-Monitor.vbs",
            Path.Combine(GetProgramDir(), "Auto-Repair-Monitor.ps1")
        );
        RegisterTask(AutoTaskName, launcher, true);
    }

    private static string BuildHiddenLauncherBody(string command)
    {
        return
            "Set shell = CreateObject(\"WScript.Shell\")" + Environment.NewLine +
            "exitCode = shell.Run(\"" + command.Replace("\"", "\"\"") + "\", 0, True)" + Environment.NewLine +
            "WScript.Quit exitCode" + Environment.NewLine;
    }

    private static string WriteHiddenLauncher(string launcherName, string script)
    {
        RequireInstalledFile(script);

        string directory = GetProgramDir();
        PrepareProtectedRoot();

        string launcher = Path.Combine(directory, launcherName);
        string temp = launcher + ".setup.tmp";
        string powershell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            @"System32\WindowsPowerShell\v1.0\powershell.exe"
        );

        string command =
            "\"" + powershell + "\"" +
            " -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " +
            "\"" + script + "\"";

        File.WriteAllText(temp, BuildHiddenLauncherBody(command), new UTF8Encoding(false));

        if (File.Exists(launcher))
        {
            File.Delete(launcher);
        }

        File.Move(temp, launcher);
        ProtectInstalledProgramFile(launcher);
        return launcher;
    }

    private static void RegisterTask(string name, string launcher, bool recurring)
    {
        PrepareProtectedRoot();
        RequireInstalledFile(launcher);
        string wscript = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            @"System32\wscript.exe"
        );
        object serviceObject = null;
        object rootObject = null;
        object taskObject = null;

        try
        {
            Type schedulerType = Type.GetTypeFromProgID("Schedule.Service");
            dynamic service = Activator.CreateInstance(schedulerType);
            serviceObject = service;
            service.Connect();
            dynamic root = service.GetFolder("\\");
            rootObject = root;
            dynamic task = service.NewTask(0);
            taskObject = task;

            task.RegistrationInfo.Description = recurring
                ? "Tailscale Quick Repair optional automatic repair monitor"
                : "Tailscale Quick Repair protected on-demand repair task";
            task.Settings.Enabled = true;
            task.Settings.AllowDemandStart = true;
            task.Settings.DisallowStartIfOnBatteries = false;
            task.Settings.StopIfGoingOnBatteries = false;
            task.Settings.ExecutionTimeLimit = recurring ? "PT2M" : "PT5M";
            task.Settings.MultipleInstances = 2; // IgnoreNew

            dynamic principal = task.Principal;
            principal.UserId = WindowsIdentity.GetCurrent().Name;
            principal.LogonType = 3;
            principal.RunLevel = 1;

            dynamic action = task.Actions.Create(0);
            action.Path = wscript;
            action.Arguments = "\"" + launcher + "\"";
            action.WorkingDirectory = Path.GetDirectoryName(launcher);

            if (recurring)
            {
                ConfigureAutoMonitorSchedule(task,DateTime.Now,WindowsIdentity.GetCurrent().User.Value);
            }

            // Give this user read/run, not task ownership or modification. Do not
            // let registration silently append a broader principal ACE.
            string sid = WindowsIdentity.GetCurrent().User.Value;
            string security = "O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGX;;;" + sid + ")";
            object registeredObject = null;
            try
            {
                dynamic registered = root.RegisterTaskDefinition(name, task, 6 | 16, null, null, 3, security);
                registeredObject = registered;
                VerifyTaskSecurity((string)registered.GetSecurityDescriptor(7), sid);
            }
            finally { ReleaseCom(registeredObject); }
        }
        finally
        {
            ReleaseCom(taskObject);
            ReleaseCom(rootObject);
            ReleaseCom(serviceObject);
        }
    }
    private static void ConfigureAutoMonitorSchedule(object definition,DateTime now,string userSid)
    {
        // Fixed local event sources, no SSID/device/user data in subscriptions.
        // No client process-exit auditing is enabled; resident UI observes that
        // transition, while exited UIs retain the five-minute fallback.
        dynamic task=definition;
        // Do not replay a missed time fallback. Resume/network/logon have their
        // own delayed local triggers, and the next PT5M fallback remains enough.
        // StartWhenAvailable can otherwise create a separate "missed task"
        // execution in addition to the regular recurrence.
        task.Settings.StartWhenAvailable=false;
        task.Settings.WakeToRun=false;
        task.Settings.RunOnlyIfNetworkAvailable=false;
        task.Settings.RestartCount=0;
        dynamic fallback=task.Triggers.Create(1);
        fallback.Id="LocalFallback";fallback.StartBoundary=now.AddMinutes(1).ToString("s");
        fallback.Repetition.Interval="PT5M"; // Unlimited; not a ten-year expiry.
        dynamic logon=task.Triggers.Create(9);
        logon.Id="LocalLogon";logon.UserId=userSid;logon.Delay="PT30S";
        string[] subscriptions={
            "<QueryList><Query Id='0' Path='System'><Select Path='System'>*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select>"+
            "<Select Path='System'>*[System[Provider[@Name='Service Control Manager'] and EventID=7036]] and *[EventData[Data[@Name='param1']='Tailscale']]</Select></Query></QueryList>",
            "<QueryList><Query Id='0' Path='Microsoft-Windows-NetworkProfile/Operational'><Select Path='Microsoft-Windows-NetworkProfile/Operational'>*[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and (EventID=10000 or EventID=10001)]]</Select></Query></QueryList>"
        };
        for(int i=0;i<subscriptions.Length;i++)
        {
            dynamic trigger=task.Triggers.Create(0);
            trigger.Id=i==0?"LocalSystemEvents":"LocalNetworkEvents";
            trigger.Subscription=subscriptions[i];trigger.Delay="PT30S";
            trigger.Repetition.Interval="PT1M";trigger.Repetition.Duration="PT2M";
            trigger.Repetition.StopAtDurationEnd=false;
        }
    }
    // Only the fixed protected install directory is hardened. Per-user app
    // files, preferences, other software and Windows directory ACLs are untouched.
    private static readonly string[] ProtectedNames = {
        "Auto-Repair-Monitor.ps1", "Repair-Backend.ps1", "TailscaleQuickRepair.Operations.dll",
        "Launch-Auto-Repair-Monitor.vbs", "Launch-Tailscale-Backend.vbs", "Advanced-Diagnostics.ps1"
    };
    // Exact pre-protected Quick Repair names observed on the long-lived 2.0
    // lineage. They are never executed by migration. A validated protected
    // update marker is required before any of these entries may be moved.
    private static readonly string[] LegacyProtectedFileNames = {
        "Launch-Tailscale-Auto-Repair.vbs", "Launch-Tailscale-Monitor.vbs",
        "NativeHost.cs", "Repair-Installation.ps1", "Repair-Tailscale.ps1",
        "Tailscale-Repair-UI.ps1", "version.json"
    };
    private static readonly string[] LegacyProtectedDirectoryNames = {
        "Rollback-2.0-Final", "Rollback-2.0-RC1", "Rollback-2.0-RC3.1", "Rollback-2.0-RC3.2"
    };
    private const int LegacyMigrationEntryLimit = 2048;
    private const long LegacyMigrationByteLimit = 64L * 1024L * 1024L;

    private static bool ContainsName(string[] names, string value)
    {
        return Array.FindIndex(names, delegate(string n) {
            return String.Equals(n, value, StringComparison.OrdinalIgnoreCase);
        }) >= 0;
    }

    private static string GetLegacyArchiveRoot()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "TailscaleQuickRepair.Legacy"
        );
    }

    private static System.Security.AccessControl.DirectorySecurity LegacyArchiveDirectorySecurity()
    {
        var security = new System.Security.AccessControl.DirectorySecurity();
        security.SetSecurityDescriptorSddlForm(
            "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
        );
        return security;
    }

    private static void RequireLegacyArchiveRootSecurity(string root)
    {
        if (!Directory.Exists(root) || File.Exists(root))
            throw new IOException("Legacy migration archive has an unexpected type.");

        CheckInstallPath(root);
        var actual = Directory.GetAccessControl(root);
        if (!actual.AreAccessRulesProtected ||
            actual.GetOwner(typeof(SecurityIdentifier)).Value != "S-1-5-32-544")
            throw new IOException("Legacy migration archive permissions are invalid.");

        bool system = false;
        bool admins = false;
        var rules = actual.GetAccessRules(true, true, typeof(SecurityIdentifier));
        foreach (System.Security.AccessControl.AuthorizationRule raw in rules)
        {
            var rule = raw as System.Security.AccessControl.FileSystemAccessRule;
            if (rule == null ||
                rule.AccessControlType != System.Security.AccessControl.AccessControlType.Allow)
                throw new IOException("Legacy migration archive permissions are invalid.");

            string sid = rule.IdentityReference.Value;
            if (sid == "S-1-5-18") system = true;
            else if (sid == "S-1-5-32-544") admins = true;
            else throw new IOException("Legacy migration archive grants an unexpected identity.");
        }

        if (!system || !admins)
            throw new IOException("Legacy migration archive permissions are incomplete.");
    }

    private static void ValidateLegacyTree(string path, ref int entries, ref long bytes)
    {
        CheckInstallPath(path);
        FileAttributes attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Legacy migration content is redirected.");

        entries++;
        if (entries > LegacyMigrationEntryLimit)
            throw new IOException("Legacy migration contains too many entries.");

        if ((attributes & FileAttributes.Directory) != 0)
        {
            foreach (string child in Directory.GetFileSystemEntries(path))
                ValidateLegacyTree(child, ref entries, ref bytes);
            return;
        }

        using (FileStream probe = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            RequireSingleLink(probe);

        bytes += new FileInfo(path).Length;
        if (bytes > LegacyMigrationByteLimit)
            throw new IOException("Legacy migration content is too large.");
    }

    private static void ValidateLegacyArchive(string archive)
    {
        RequireLegacyArchiveRootSecurity(archive);
        int entries = 0;
        long bytes = 0;

        foreach (string item in Directory.GetFileSystemEntries(archive))
        {
            string name = Path.GetFileName(item);
            if (ContainsName(LegacyProtectedFileNames, name))
            {
                if (!File.Exists(item) || Directory.Exists(item))
                    throw new IOException("Legacy migration archive has an unexpected entry type.");
            }
            else if (ContainsName(LegacyProtectedDirectoryNames, name))
            {
                if (!Directory.Exists(item) || File.Exists(item))
                    throw new IOException("Legacy migration archive has an unexpected entry type.");
            }
            else
                throw new IOException("Legacy migration archive contains unexpected content.");

            ValidateLegacyTree(item, ref entries, ref bytes);
        }
    }

    private static void MigrateKnownLegacyProtectedLayout()
    {
        // Never move legacy-looking content during a fresh install or ordinary
        // maintenance. The protected bridge marker is validated by the caller
        // immediately before ApplyFiles reaches this boundary.
        if (!File.Exists(GetProtectedUpdateMarkerPath())) return;

        string root = GetProgramDir();
        if (!Directory.Exists(root))
        {
            if (File.Exists(root))
                throw new IOException("Protected installation root has an unexpected type.");
            return;
        }

        CheckInstallPath(root);
        List<string> pending = new List<string>();
        int entries = 0;
        long bytes = 0;

        // Validate the complete active root before moving the first byte.
        foreach (string item in Directory.GetFileSystemEntries(root))
        {
            string name = Path.GetFileName(item);

            if (ContainsName(ProtectedNames, name))
            {
                if (!File.Exists(item) || Directory.Exists(item))
                    throw new IOException("Protected installation has unexpected content. Existing files were preserved.");
                continue;
            }

            if (ContainsName(LegacyProtectedFileNames, name))
            {
                if (!File.Exists(item) || Directory.Exists(item))
                    throw new IOException("Legacy protected content has an unexpected type.");
                ValidateLegacyTree(item, ref entries, ref bytes);
                pending.Add(item);
                continue;
            }

            if (ContainsName(LegacyProtectedDirectoryNames, name))
            {
                if (!Directory.Exists(item) || File.Exists(item))
                    throw new IOException("Legacy protected content has an unexpected type.");
                ValidateLegacyTree(item, ref entries, ref bytes);
                pending.Add(item);
                continue;
            }

            throw new IOException("Protected installation has unexpected content. Existing files were preserved.");
        }

        if (pending.Count == 0) return;

        string archive = GetLegacyArchiveRoot();
        CheckInstallPath(archive);
        if (File.Exists(archive))
            throw new IOException("Legacy migration archive is occupied by a file.");

        if (!Directory.Exists(archive))
            Directory.CreateDirectory(archive, LegacyArchiveDirectorySecurity());

        ValidateLegacyArchive(archive);
        pending.Sort(StringComparer.OrdinalIgnoreCase);

        foreach (string source in pending)
        {
            string name = Path.GetFileName(source);
            string destination = Path.Combine(archive, name);

            if (File.Exists(destination) || Directory.Exists(destination))
                throw new IOException("Legacy migration archive already contains this entry.");

            if (Directory.Exists(source))
                Directory.Move(source, destination);
            else if (File.Exists(source))
                File.Move(source, destination);
            else
                throw new IOException("Legacy migration source changed during migration.");
        }

        ValidateLegacyArchive(archive);
    }

    private static void CheckInstallPath(string path)
    {
        for (string p = Path.GetFullPath(path); !String.IsNullOrEmpty(p); p = Path.GetDirectoryName(p))
        {
            try { if ((File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0) throw new IOException("Protected install path is redirected."); }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }
    private static System.Security.AccessControl.DirectorySecurity ProtectedDirectorySecurity()
    {
        var security = new System.Security.AccessControl.DirectorySecurity();
        security.SetSecurityDescriptorSddlForm("O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FRFX;;;BU)");
        return security;
    }
    private static void PrepareProtectedRoot()
    {
        if (!IsAdministrator()) throw new UnauthorizedAccessException("Protected installation requires administrator approval.");
        string root = GetProgramDir();
        CheckInstallPath(root);
        if (Directory.Exists(root))
        {
            // Reject unfamiliar/nested/redirected content rather than recursively
            // taking ownership of it. Interrupted-install evidence is preserved.
            foreach (string entry in Directory.GetFileSystemEntries(root))
            {
                if (Array.FindIndex(ProtectedNames, delegate(string n) { return String.Equals(n, Path.GetFileName(entry), StringComparison.OrdinalIgnoreCase); }) < 0 || Directory.Exists(entry))
                    throw new IOException("Protected installation has unexpected content. Existing files were preserved.");
                CheckInstallPath(entry);
                using (FileStream probe = new FileStream(entry, FileMode.Open, FileAccess.Read, FileShare.Read))
                    RequireSingleLink(probe);
            }
        }
        else Directory.CreateDirectory(root, ProtectedDirectorySecurity());
        Directory.SetAccessControl(root, ProtectedDirectorySecurity());
        var actual = Directory.GetAccessControl(root);
        if (!actual.AreAccessRulesProtected || actual.GetOwner(typeof(SecurityIdentifier)).Value != "S-1-5-32-544")
            throw new IOException("Protected directory ownership verification failed.");
        foreach (string file in Directory.GetFiles(root)) ProtectInstalledProgramFile(file);
    }
    private static void ProtectInstalledProgramFile(string path)
    {
        string root = EnsureTrailingSeparator(Path.GetFullPath(GetProgramDir()));
        string full = Path.GetFullPath(path);
        if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return;
        if (!String.Equals(Path.GetDirectoryName(full) + Path.DirectorySeparatorChar, root, StringComparison.OrdinalIgnoreCase) ||
            Array.FindIndex(ProtectedNames, delegate(string n) { return String.Equals(n, Path.GetFileName(full), StringComparison.OrdinalIgnoreCase); }) < 0)
            throw new IOException("Unexpected protected installation target.");
        CheckInstallPath(full);
        using (FileStream probe = new FileStream(full, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            RequireSingleLink(probe); // Keep the file pinned against replacement.
            var security = new System.Security.AccessControl.FileSecurity();
            security.SetSecurityDescriptorSddlForm("O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFX;;;BU)");
            File.SetAccessControl(full, security);
            var actual = File.GetAccessControl(full);
            if (!actual.AreAccessRulesProtected || actual.GetOwner(typeof(SecurityIdentifier)).Value != "S-1-5-32-544")
                throw new IOException("Protected file ownership verification failed.");
        }
    }
    private static void RequireSingleLink(FileStream file)
    {
        NativeFileInformation info;
        if (!GetFileInformationByHandle(file.SafeFileHandle, out info) || info.links != 1 || (info.attributes & 0x400) != 0)
            throw new IOException("Protected installation file has an unsupported link layout.");
    }
    private static void VerifyTaskSecurity(string sddl, string user)
    {
        var security = new System.Security.AccessControl.RawSecurityDescriptor(sddl);
        if (security.Owner == null || security.Owner.Value != "S-1-5-32-544" || security.DiscretionaryAcl == null)
            throw new IOException("Protected task ownership verification failed.");
        bool foundUser = false;
        foreach (System.Security.AccessControl.GenericAce raw in security.DiscretionaryAcl)
        {
            var ace = raw as System.Security.AccessControl.CommonAce;
            if (ace == null || ace.AceQualifier != System.Security.AccessControl.AceQualifier.AccessAllowed)
                throw new IOException("Unexpected protected task permissions.");
            string sid = ace.SecurityIdentifier.Value;
            if (sid == "S-1-5-18" || sid == "S-1-5-32-544") continue;
            // Read/execute may be expressed as generic or mapped file rights.
            if (sid != user || ((uint)ace.AccessMask & ~0xA01200A9u) != 0)
                throw new IOException("Protected task grants excess permissions.");
            foundUser = true;
        }
        if (!foundUser) throw new IOException("Protected task has no ordinary read/run grant.");
    }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct NativeFileInformation
    {
        public uint attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME creation, access, write;
        public uint volume, sizeHigh, sizeLow, links, indexHigh, indexLow;
    }
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle handle, out NativeFileInformation info);

    private const string RestartRegistryPath = @"Software\TailscaleQuickRepair";
    private const string RestartRegistryName = "PendingRestartVersionCode";

    private static void WriteRestartPending(long versionCode)
    {
        if (versionCode <= 0) throw new InvalidDataException("Restart acknowledgement version is invalid.");
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RestartRegistryPath))
        {
            if (key == null) throw new IOException("Restart acknowledgement could not be written.");
            key.SetValue(RestartRegistryName, versionCode, RegistryValueKind.QWord);
            object value = key.GetValue(RestartRegistryName, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
            if (value == null || Convert.ToInt64(value) != versionCode)
                throw new IOException("Restart acknowledgement could not be verified.");
        }
    }

    private static string GetProtectedUpdateMarkerPath()
    {
        return Path.Combine(GetAppDir(), "protected-update.json");
    }

    private static void ValidateProtectedUpdateMarker(long versionCode, string channel)
    {
        string path = GetProtectedUpdateMarkerPath();
        if (!File.Exists(path)) return;

        Dictionary<string, object> marker = Deserialize(File.ReadAllText(path, Encoding.UTF8));
        int schema = ReadInt(marker, "schema");
        string normalizedChannel = NormalizeChannel(channel);

        if (schema == 1)
        {
            if (marker.Count != 2 || ReadLong(marker, "versionCode") != versionCode ||
                !String.Equals(normalizedChannel, "stable", StringComparison.Ordinal))
                throw new InvalidDataException("Protected update marker does not match this release.");
            return;
        }

        if (schema == 2)
        {
            string markerChannel = NormalizeChannel(ReadString(marker, "channel"));
            if (marker.Count != 3 || ReadLong(marker, "versionCode") != versionCode ||
                !String.Equals(markerChannel, normalizedChannel, StringComparison.Ordinal))
                throw new InvalidDataException("Protected update marker does not match this release.");
            return;
        }

        throw new InvalidDataException("Protected update marker is invalid.");
    }
    private static void RemoveProtectedUpdateMarker()
    {
        string path = GetProtectedUpdateMarkerPath();
        if (File.Exists(path)) File.Delete(path);
    }

    private static void WriteLocalConfig(string peer)
    {
        Directory.CreateDirectory(GetAppDir());
        string path = Path.Combine(GetAppDir(), "config.json");
        string temp = path + ".setup.tmp";
        File.WriteAllText(temp, Json.Serialize(new Dictionary<string, object> { { "peer", peer } }), new UTF8Encoding(false));
        if (File.Exists(path)) File.Delete(path);
        File.Move(temp, path);
    }

    private static string ReadConfiguredPeer()
    {
        string path = Path.Combine(GetAppDir(), "config.json");
        if (!File.Exists(path)) throw new InvalidDataException("No target is configured. Run Setup again and choose a target.");
        Dictionary<string, object> config = Deserialize(File.ReadAllText(path, Encoding.UTF8));
        return NormalizePeer(ReadString(config, "peer"));
    }

    private static void ConfigureStartup(bool enabled)
    {
        using (RegistryKey run = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
        {
            if (enabled)
            {
                string command = "\"" + Path.Combine(GetAppDir(), "TailscaleQuickRepair.exe") + "\" --start-in-tray";
                run.SetValue(StartupName, command, RegistryValueKind.String);
            }
            else run.DeleteValue(StartupName, false);
        }
    }

    private static bool IsStartupEnabled()
    {
        using (RegistryKey run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
        {
            object value = run == null ? null : run.GetValue(StartupName);
            return value != null && !String.IsNullOrWhiteSpace(value.ToString());
        }
    }

    private static void CreateStartMenuShortcut()
    {
        string shortcut = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Programs),
            "Tailscale Quick Repair.lnk"
        );
        WriteQuickRepairShortcut(shortcut);
        RefreshDesktopShortcuts();
    }

    private static void RefreshDesktopShortcuts()
    {
        string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);

        foreach (string name in new[] { "Fix Tailscale.lnk", "Tailscale Quick Repair.lnk" })
        {
            string shortcut = Path.Combine(desktop, name);

            if (File.Exists(shortcut))
            {
                WriteQuickRepairShortcut(shortcut);
            }
        }
    }

    private static void WriteQuickRepairShortcut(string shortcut)
    {
        Type shellType = Type.GetTypeFromProgID("WScript.Shell");
        object shellObject = null;
        object shortcutObject = null;
        string exe = Path.Combine(GetAppDir(), "TailscaleQuickRepair.exe");

        try
        {
            dynamic shell = Activator.CreateInstance(shellType);
            shellObject = shell;
            dynamic link = shell.CreateShortcut(shortcut);
            shortcutObject = link;
            link.TargetPath = exe;
            link.WorkingDirectory = GetAppDir();
            link.Description = "Tailscale Quick Repair";
            link.IconLocation = exe + ",0";
            link.Save();
        }
        finally
        {
            ReleaseCom(shortcutObject);
            ReleaseCom(shellObject);
        }
    }

    private static void StopQuickRepair()
    {
        foreach (Process process in Process.GetProcessesByName("TailscaleQuickRepair"))
        {
            try { process.CloseMainWindow(); if (!process.WaitForExit(2500)) process.Kill(); } catch { }
            finally { process.Dispose(); }
        }
    }

    private static void StartQuickRepair()
    {
        string exe = Path.Combine(GetAppDir(), "TailscaleQuickRepair.exe");
        if (File.Exists(exe)) Process.Start(new ProcessStartInfo { FileName = exe, UseShellExecute = true });
    }

    private static SetupChoice ShowSetupDialog()
    {
        using (Form form = new Form())
        using (Label title = new Label())
        using (Label description = new Label())
        using (TextBox peer = new TextBox())
        using (CheckBox startup = new CheckBox())
        using (Label error = new Label())
        using (Button install = new Button())
        using (Button cancel = new Button())
        {
            form.Text = "Tailscale Quick Repair Setup";
            form.StartPosition = FormStartPosition.CenterScreen;
            form.FormBorderStyle = FormBorderStyle.FixedDialog;
            form.MaximizeBox = false;
            form.MinimizeBox = false;
            form.ClientSize = new Size(520, 280);
            form.BackColor = Color.FromArgb(10, 13, 18);
            form.ForeColor = Color.FromArgb(247, 248, 250);
            form.Font = new Font("Segoe UI", 9F);

            title.Text = "Choose the Tailscale target";
            title.Font = new Font("Segoe UI Semibold", 16F);
            title.AutoSize = true;
            title.Location = new Point(28, 24);

            description.Text = "Enter the Tailscale IP or MagicDNS name of the machine you want Quick Repair to check — for example the PC or VPS you use for RDP.";
            description.ForeColor = Color.FromArgb(143, 155, 168);
            description.Location = new Point(30, 66);
            description.Size = new Size(455, 48);

            peer.Location = new Point(32, 124);
            peer.Size = new Size(452, 28);
            peer.BackColor = Color.FromArgb(21, 26, 33);
            peer.ForeColor = Color.White;
            peer.BorderStyle = BorderStyle.FixedSingle;

            startup.Text = "Start Quick Repair with Windows";
            startup.Checked = true;
            startup.AutoSize = true;
            startup.Location = new Point(32, 166);
            startup.BackColor = form.BackColor;
            startup.ForeColor = form.ForeColor;

            error.Location = new Point(32, 194);
            error.Size = new Size(452, 20);
            error.ForeColor = Color.FromArgb(255, 107, 120);

            cancel.Text = "Cancel";
            cancel.Location = new Point(310, 226);
            cancel.Size = new Size(82, 34);
            cancel.DialogResult = DialogResult.Cancel;

            install.Text = "Install";
            install.Location = new Point(400, 226);
            install.Size = new Size(84, 34);
            install.BackColor = Color.FromArgb(8, 102, 255);
            install.ForeColor = Color.White;
            install.FlatStyle = FlatStyle.Flat;
            install.FlatAppearance.BorderSize = 0;

            form.Controls.AddRange(new Control[] { title, description, peer, startup, error, cancel, install });
            form.CancelButton = cancel;
            form.AcceptButton = install;

            SetupChoice choice = null;
            install.Click += delegate
            {
                try
                {
                    choice = new SetupChoice { Peer = NormalizePeer(peer.Text), StartWithWindows = startup.Checked };
                    form.DialogResult = DialogResult.OK;
                    form.Close();
                }
                catch (Exception ex)
                {
                    error.Text = ex.Message;
                    peer.Focus();
                    peer.SelectAll();
                }
            };

            return form.ShowDialog() == DialogResult.OK ? choice : null;
        }
    }

    private static string NormalizePeer(string value)
    {
        if (String.IsNullOrWhiteSpace(value)) throw new ArgumentException("Enter a Tailscale IP or MagicDNS name.");
        string candidate = value.Trim();
        if (candidate.Length > 255 || Regex.IsMatch(candidate, @"\s")) throw new ArgumentException("Enter a valid Tailscale IP or MagicDNS name.");

        IPAddress address;
        if (IPAddress.TryParse(candidate, out address)) return address.ToString();
        if (!Regex.IsMatch(candidate, @"^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,253}[A-Za-z0-9])?$"))
            throw new ArgumentException("Enter a valid Tailscale IP or MagicDNS name.");
        return candidate;
    }

    private static int RelaunchElevated(string peer, bool startup, bool repairOnly, bool upgradeOnly, string requesterSid, string channel, long targetCode)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = Process.GetCurrentProcess().MainModule.FileName;
            string mode = repairOnly ? "--repair " : upgradeOnly ? "--upgrade " : "";
            psi.Arguments = mode + "--peer " + Quote(peer) +
                " --startup " + (startup ? "true" : "false") +
                " --channel " + Quote(NormalizeChannel(channel)) +
                " --target-code " + targetCode.ToString(CultureInfo.InvariantCulture) +
                " --requester-sid " + Quote(NormalizeSid(requesterSid));
            psi.Verb = "runas";
            psi.UseShellExecute = true;
            Process child = Process.Start(psi);
            return child == null ? 5 : 0;
        }
        catch { return 5; }
    }

    private static string CurrentUserSid()
    {
        using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
        {
            if (identity == null || identity.User == null)
                throw new UnauthorizedAccessException("The Windows account could not be verified.");
            return identity.User.Value;
        }
    }

    private static string NormalizeSid(string value)
    {
        if (String.IsNullOrWhiteSpace(value))
            throw new UnauthorizedAccessException("The Windows account could not be verified.");
        try
        {
            SecurityIdentifier sid = new SecurityIdentifier(value.Trim());
            return sid.Value;
        }
        catch
        {
            throw new UnauthorizedAccessException("The Windows account could not be verified.");
        }
    }

    private static void RequireRequesterIdentity(string requesterSid)
    {
        if (String.IsNullOrWhiteSpace(requesterSid)) return;
        string expected = NormalizeSid(requesterSid);
        if (!String.Equals(CurrentUserSid(), expected, StringComparison.Ordinal))
            throw new UnauthorizedAccessException(
                "Setup must be approved by the same Windows account that started Quick Repair."
            );
    }

    private static bool IsAdministrator()
    {
        WindowsPrincipal principal = new WindowsPrincipal(WindowsIdentity.GetCurrent());
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static string DownloadString(string url, bool api)
    {
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(url);
        request.Method = "GET";
        request.UserAgent = "TailscaleQuickRepairSetup/3.0";
        request.Timeout = 15000;
        request.ReadWriteTimeout = 15000;
        request.Proxy = WebRequest.DefaultWebProxy;
        if (request.Proxy != null) request.Proxy.Credentials = CredentialCache.DefaultNetworkCredentials;
        if (api)
        {
            request.Accept = "application/vnd.github+json";
            request.Headers["X-GitHub-Api-Version"] = "2022-11-28";
        }
        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        using (Stream stream = response.GetResponseStream())
        using (StreamReader reader = new StreamReader(stream, Encoding.UTF8)) return reader.ReadToEnd();
    }

    private static void DownloadFile(string url, string destination)
    {
        if (!IsTrustedReleaseUrl(url)) throw new InvalidDataException("Refusing an untrusted setup URL.");
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(url);
        request.Method = "GET";
        request.UserAgent = "TailscaleQuickRepairSetup/3.0";
        request.Timeout = 30000;
        request.ReadWriteTimeout = 30000;
        request.AllowAutoRedirect = true;
        request.Proxy = WebRequest.DefaultWebProxy;
        if (request.Proxy != null) request.Proxy.Credentials = CredentialCache.DefaultNetworkCredentials;
        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        using (Stream input = response.GetResponseStream())
        using (FileStream output = File.Create(destination)) input.CopyTo(output);
    }

    private static bool IsTrustedReleaseUrl(string value)
    {
        Uri uri;
        return Uri.TryCreate(value, UriKind.Absolute, out uri) &&
               uri.Scheme == "https" &&
               String.Equals(uri.Host, TrustedHost, StringComparison.OrdinalIgnoreCase) &&
               uri.AbsolutePath.StartsWith(TrustedReleasePrefix, StringComparison.Ordinal);
    }

    private static string Sha256File(string path)
    {
        using (SHA256 sha = SHA256.Create())
        using (FileStream stream = File.OpenRead(path))
        {
            byte[] hash = sha.ComputeHash(stream);
            StringBuilder value = new StringBuilder(hash.Length * 2);
            foreach (byte b in hash) value.Append(b.ToString("x2"));
            return value.ToString();
        }
    }

    private static bool IsSha256(string value)
    {
        return !String.IsNullOrEmpty(value) && Regex.IsMatch(value, "^[0-9a-fA-F]{64}$");
    }

    private static void RequirePackageFile(List<InstallFile> files, string path)
    {
        foreach (InstallFile file in files)
            if (String.Equals(file.RelativePath.Replace('\\', '/'), path, StringComparison.OrdinalIgnoreCase)) return;
        throw new InvalidDataException("Required setup component is missing: " + path);
    }

    private static void RequireInstalledFile(string path)
    {
        if (!File.Exists(path)) throw new FileNotFoundException("Quick Repair is missing a required component. Run Setup again.", path);
    }

    private static Dictionary<string, object> Deserialize(string json)
    {
        Dictionary<string, object> value = Json.Deserialize<Dictionary<string, object>>(json);
        if (value == null) throw new InvalidDataException("Invalid JSON response.");
        return value;
    }

    private static Dictionary<string, object> ReadDictionary(Dictionary<string, object> source, string key)
    {
        object value;
        if (!source.TryGetValue(key, out value)) throw new InvalidDataException("Missing JSON object: " + key);
        Dictionary<string, object> result = value as Dictionary<string, object>;
        if (result == null) throw new InvalidDataException("Invalid JSON object: " + key);
        return result;
    }

    private static string ReadString(Dictionary<string, object> source, string key)
    {
        object value;
        return source.TryGetValue(key, out value) && value != null ? Convert.ToString(value) : String.Empty;
    }

    private static long ReadLong(Dictionary<string, object> source, string key)
    {
        object value;
        return source.TryGetValue(key, out value) && value != null ? Convert.ToInt64(value) : 0;
    }

    private static int ReadInt(Dictionary<string, object> source, string key) { return (int)ReadLong(source, key); }
    private static bool ReadBool(Dictionary<string, object> source, string key)
    {
        object value;
        return source.TryGetValue(key, out value) && value != null && Convert.ToBoolean(value);
    }

    private static long ReadLongArg(string[] args, string name, long fallback)
    {
        string value = ReadArg(args, name);
        long parsed;
        return Int64.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed)
            ? parsed
            : fallback;
    }

    private static string ReadArg(string[] args, string name)
    {
        for (int i = 0; i < args.Length - 1; i++)
            if (String.Equals(args[i], name, StringComparison.OrdinalIgnoreCase)) return args[i + 1];
        return String.Empty;
    }

    private static bool HasSwitch(string[] args, string name)
    {
        foreach (string arg in args) if (String.Equals(arg, name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    private static string Quote(string value) { return "\"" + (value ?? "").Replace("\"", "\\\"") + "\""; }
    private static string EnsureTrailingSeparator(string path) { return path.EndsWith(Path.DirectorySeparatorChar.ToString()) ? path : path + Path.DirectorySeparatorChar; }
    private static string GetAppDir() { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TailscaleQuickRepair"); }
    private static string GetProgramDir() { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "TailscaleQuickRepair"); }

    private static void ReleaseCom(object value)
    {
        if (value == null) return;
        try { System.Runtime.InteropServices.Marshal.FinalReleaseComObject(value); } catch { }
    }

    private sealed class SetupChoice { public string Peer; public bool StartWithWindows; }
    private sealed class SetupManifest { public string Version; public long VersionCode; public string Url; public string Sha256; public long Size; }
    private sealed class PackageManifest { public string Version; public long VersionCode; public List<PackageFile> Files; }
    private sealed class PackageFile { public string Path; public string Sha256; public long Size; }
    private sealed class InstallFile { public string Source; public string Target; public string RelativePath; public string Sha256; }
    private sealed class BackupEntry { public string Target; public string Backup; public bool Existed; }
    private sealed class RecoveryDocument { public int schema; public string state; public string userSid; public RecoveryEntry[] entries; }
    private sealed class RecoveryEntry { public string path; public bool existed; public string backup; public string sha256; public long size; public string newSha256; }
}
