using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Tailscale Quick Repair Updater")]
[assembly: System.Reflection.AssemblyProduct("Tailscale Quick Repair")]
[assembly: System.Reflection.AssemblyVersion("3.0.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("3.0.0.1")]

internal static class Program
{
    private const string StableManifestApiUrl =
        "https://api.github.com/repos/coachedai/tailscale-repair-clean/contents/updates/latest.json?ref=main";
    private const string PreviewManifestApiUrl =
        "https://api.github.com/repos/coachedai/tailscale-repair-clean/contents/updates/preview.json?ref=preview";
    private const string StableManifestPath = "updates/latest.json";
    private const string PreviewManifestPath = "updates/preview.json";

    private const string TrustedHost = "github.com";
    private const string TrustedReleasePrefix =
        "/coachedai/tailscale-repair-clean/releases/download/";

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

    [STAThread]
    private static int Main(string[] args)
    {
        bool silent = HasSwitch(args, "--silent");
        int currentPid = ReadIntArg(args, "--current-pid", 0);
        long currentCode = ReadLongArg(args, "--current-code", ReadInstalledVersionCode());
        long targetCode = ReadLongArg(args, "--target-code", 0);
        string channel = NormalizeChannel(ReadArg(args, "--channel"));

        string workDir = Path.Combine(
            Path.GetTempPath(),
            "TailscaleQuickRepair-NativeUpdate-" + Guid.NewGuid().ToString("N")
        );
        bool operationAcquired = false;
        bool recoveredPreviousTransaction = false;

        try
        {
            Directory.CreateDirectory(workDir);

            if (!TryAcquireOperationLock("update"))
                throw new InvalidOperationException("Another Quick Repair operation is already running. Try the update again when it finishes.");

            operationAcquired = true;

            // Never discard recovery data from an interrupted updater. Restore
            // the verified predecessor first, then start a fresh transaction.
            recoveredPreviousTransaction = RecoverInterruptedTransaction();

            UpdateManifest manifest = FetchManifest(channel);

            if (!manifest.Published)
            {
                return Finish(
                    silent,
                    0,
                    "No update is currently published.",
                    MessageBoxIcon.Information
                );
            }

            if (targetCode > 0 && manifest.VersionCode != targetCode)
            {
                throw new InvalidDataException("The selected update changed. Check for updates again.");
            }

            if (manifest.VersionCode <= currentCode)
            {
                return Finish(
                    silent,
                    0,
                    "Tailscale Quick Repair is already up to date.",
                    MessageBoxIcon.Information
                );
            }

            if (!silent)
            {
                DialogResult answer = MessageBox.Show(
                    "Install Tailscale Quick Repair " + manifest.Version + "?\r\n\r\n" +
                    manifest.Notes + "\r\n\r\n" +
                    "The release package will be verified before any files are replaced.",
                    "Tailscale Quick Repair",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Information
                );

                if (answer != DialogResult.Yes)
                {
                    return 0;
                }
            }

            if (manifest.RequiresSetup)
                throw new InvalidOperationException("This release updates protected components. Open Quick Repair and use Update now, or run the release Setup installer. The ordinary package was not applied.");

            PreserveLocalPeerConfiguration();

            if (currentPid > 0)
            {
                WaitForProcessExit(currentPid, TimeSpan.FromSeconds(25));
            }

            string packagePath = Path.Combine(workDir, "update.zip");
            DownloadFile(manifest.PackageUrl, packagePath);

            FileInfo downloaded = new FileInfo(packagePath);
            if (downloaded.Length != manifest.PackageSize)
            {
                throw new InvalidDataException(
                    "Downloaded package size did not match the trusted manifest."
                );
            }

            string packageHash = Sha256File(packagePath);
            if (!String.Equals(
                packageHash,
                manifest.PackageSha256,
                StringComparison.OrdinalIgnoreCase
            ))
            {
                throw new InvalidDataException(
                    "Downloaded package failed SHA-256 verification."
                );
            }

            string extractDir = Path.Combine(workDir, "package");
            Directory.CreateDirectory(extractDir);
            ZipFile.ExtractToDirectory(packagePath, extractDir);

            PackageManifest package = ReadPackageManifest(extractDir);

            if (package.VersionCode != manifest.VersionCode ||
                !String.Equals(package.Version, manifest.Version, StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Package metadata does not match the trusted update manifest."
                );
            }

            List<VerifiedFile> files = VerifyPackageFiles(extractDir, package);
            ValidatePackageChannelBinding(files, channel, manifest.VersionCode);

            if (files.Count == 0)
            {
                throw new InvalidDataException("The update package contains no installable files.");
            }

            ApplyTransaction(files, manifest.Version, manifest.VersionCode);
            WriteResult(
                true,
                manifest.Version,
                "installed",
                "none",
                recoveredPreviousTransaction
            );
            StartQuickRepair();

            return Finish(
                silent,
                0,
                "Tailscale Quick Repair " + manifest.Version + " was installed successfully.",
                MessageBoxIcon.Information
            );
        }
        catch (Exception ex)
        {
            string outcome = GetFailureOutcome(ex);
            string reason = GetFailureReason(ex);
            string safeMessage = GetSafeResultMessage(
                outcome,
                reason,
                recoveredPreviousTransaction
            );

            WriteResult(
                false,
                String.Empty,
                outcome,
                reason,
                recoveredPreviousTransaction
            );
            StartQuickRepair();

            return Finish(
                silent,
                10,
                safeMessage,
                outcome == "recovery_required"
                    ? MessageBoxIcon.Error
                    : MessageBoxIcon.Warning
            );
        }
        finally
        {
            if (operationAcquired) ReleaseOperationLock();

            try
            {
                if (Directory.Exists(workDir))
                {
                    Directory.Delete(workDir, true);
                }
            }
            catch { }
        }
    }

    private static int Finish(bool silent, int code, string message, MessageBoxIcon icon)
    {
        if (!silent)
        {
            try
            {
                MessageBox.Show(
                    message,
                    "Tailscale Quick Repair",
                    MessageBoxButtons.OK,
                    icon
                );
            }
            catch { }
        }

        return code;
    }

    internal static string NormalizeChannel(string value)
    {
        if (String.IsNullOrWhiteSpace(value) ||
            String.Equals(value, "stable", StringComparison.OrdinalIgnoreCase))
        {
            return "stable";
        }

        if (String.Equals(value, "preview", StringComparison.OrdinalIgnoreCase))
        {
            return "preview";
        }

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

    private static UpdateManifest FetchManifest(string channel)
    {
        channel = NormalizeChannel(channel);
        string apiJson = DownloadString(GetManifestApiUrl(channel), true);
        Dictionary<string, object> api = DeserializeObject(apiJson);

        string encoding = ReadString(api, "encoding");
        string apiPath = ReadString(api, "path");
        string content = ReadString(api, "content").Replace("\n", String.Empty).Replace("\r", String.Empty);

        if (!String.Equals(encoding, "base64", StringComparison.OrdinalIgnoreCase) ||
            !String.Equals(apiPath, GetExpectedManifestPath(channel), StringComparison.Ordinal) ||
            String.IsNullOrWhiteSpace(content))
        {
            throw new InvalidDataException("GitHub returned an unexpected update-channel response.");
        }

        string manifestText = Encoding.UTF8.GetString(Convert.FromBase64String(content));
        Dictionary<string, object> root = DeserializeObject(manifestText);

        if (ReadInt(root, "schema") != 1)
        {
            throw new InvalidDataException("Unsupported update manifest schema.");
        }

        if (channel == "preview" &&
            !String.Equals(ReadString(root, "channel"), "preview", StringComparison.Ordinal))
        {
            throw new InvalidDataException("The Early-access manifest channel is invalid.");
        }

        UpdateManifest result = new UpdateManifest();
        result.Published = ReadBool(root, "published");
        result.Version = ReadString(root, "version");
        result.VersionCode = ReadLong(root, "versionCode");
        result.Notes = ReadString(root, "notes");
        object requiresSetup;
        if (root.TryGetValue("requiresSetup", out requiresSetup)) {
            if (!(requiresSetup is bool)) throw new InvalidDataException("Protected-update metadata is invalid.");
            result.RequiresSetup = (bool)requiresSetup;
        }

        if (!result.Published)
        {
            return result;
        }

        Dictionary<string, object> package = ReadDictionary(root, "package");
        result.PackageUrl = ReadString(package, "url");
        result.PackageSha256 = ReadString(package, "sha256").ToLowerInvariant();
        result.PackageSize = ReadLong(package, "size");

        if (String.IsNullOrWhiteSpace(result.Version) ||
            result.VersionCode <= 0 ||
            result.PackageSize <= 0 ||
            !IsSha256(result.PackageSha256) ||
            !IsTrustedReleaseUrl(result.PackageUrl))
        {
            throw new InvalidDataException("The update manifest failed trust validation.");
        }

        return result;
    }
    private static PackageManifest ReadPackageManifest(string root)
    {
        string path = Path.Combine(root, "package-manifest.json");

        if (!File.Exists(path))
        {
            throw new InvalidDataException("The update package is missing package-manifest.json.");
        }

        Dictionary<string, object> data = DeserializeObject(File.ReadAllText(path, Encoding.UTF8));

        if (ReadInt(data, "schema") != 1)
        {
            throw new InvalidDataException("Unsupported package manifest schema.");
        }

        PackageManifest manifest = new PackageManifest();
        manifest.Version = ReadString(data, "version");
        manifest.VersionCode = ReadLong(data, "versionCode");
        manifest.Files = new List<PackageFile>();

        object rawFiles;
        if (!data.TryGetValue("files", out rawFiles))
        {
            throw new InvalidDataException("Package manifest contains no files array.");
        }

        object[] items = rawFiles as object[];
        if (items == null)
        {
            System.Collections.ArrayList list = rawFiles as System.Collections.ArrayList;
            if (list != null)
            {
                items = list.ToArray();
            }
        }

        if (items == null)
        {
            throw new InvalidDataException("Package manifest files array is invalid.");
        }

        foreach (object item in items)
        {
            Dictionary<string, object> entry = item as Dictionary<string, object>;
            if (entry == null)
            {
                throw new InvalidDataException("Package manifest contains an invalid file entry.");
            }

            PackageFile file = new PackageFile();
            file.Path = ReadString(entry, "path");
            file.Sha256 = ReadString(entry, "sha256").ToLowerInvariant();
            file.Size = ReadLong(entry, "size");

            if (String.IsNullOrWhiteSpace(file.Path) ||
                !IsSha256(file.Sha256) ||
                file.Size < 0)
            {
                throw new InvalidDataException("Package manifest contains invalid file metadata.");
            }

            manifest.Files.Add(file);
        }

        return manifest;
    }

    private static List<VerifiedFile> VerifyPackageFiles(string extractDir, PackageManifest package)
    {
        string root = EnsureTrailingSeparator(Path.GetFullPath(extractDir));
        List<VerifiedFile> verified = new List<VerifiedFile>();

        foreach (PackageFile file in package.Files)
        {
            string relative = file.Path.Replace('/', Path.DirectorySeparatorChar);
            string source = Path.GetFullPath(Path.Combine(extractDir, relative));

            if (!source.StartsWith(root, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("Package path escapes staging directory: " + file.Path);
            }

            if (!File.Exists(source))
            {
                throw new InvalidDataException("Package file is missing: " + file.Path);
            }

            FileInfo info = new FileInfo(source);
            if (info.Length != file.Size)
            {
                throw new InvalidDataException("Package file size mismatch: " + file.Path);
            }

            if (!String.Equals(Sha256File(source), file.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("Package file hash mismatch: " + file.Path);
            }

            string target = ResolveTarget(file.Path);

            VerifiedFile item = new VerifiedFile();
            item.RelativePath = file.Path;
            item.SourcePath = source;
            item.TargetPath = target;
            item.Sha256 = file.Sha256;
            verified.Add(item);
        }

        return verified;
    }

    private static void ValidatePackageChannelBinding(List<VerifiedFile> files, string channel, long versionCode)
    {
        channel = NormalizeChannel(channel);
        List<VerifiedFile> markers = files.FindAll(delegate(VerifiedFile file)
        {
            return String.Equals(file.RelativePath.Replace('\\', '/'), "app/protected-update.json", StringComparison.OrdinalIgnoreCase);
        });

        if (markers.Count == 0) return;
        if (markers.Count != 1) throw new InvalidDataException("Update package contains an invalid protected handoff marker set.");

        ValidateProtectedHandoffMarker(
            File.ReadAllText(markers[0].SourcePath, Encoding.UTF8),
            channel,
            versionCode
        );
    }

    internal static void ValidateProtectedHandoffMarker(string markerJson, string channel, long versionCode)
    {
        channel = NormalizeChannel(channel);
        Dictionary<string, object> marker = DeserializeObject(markerJson);
        int schema = ReadInt(marker, "schema");
        if (ReadLong(marker, "versionCode") != versionCode)
            throw new InvalidDataException("Protected handoff marker version does not match the selected update.");

        if (schema == 1)
        {
            if (marker.Count != 2 || channel != "stable")
                throw new InvalidDataException("Legacy protected handoff marker is valid only on Stable.");
            return;
        }

        if (schema == 2)
        {
            string markerChannel = NormalizeChannel(ReadString(marker, "channel"));
            if (marker.Count != 3 || !String.Equals(markerChannel, channel, StringComparison.Ordinal))
                throw new InvalidDataException("Protected handoff marker channel does not match the selected update.");
            return;
        }

        throw new InvalidDataException("Unsupported protected handoff marker schema.");
    }

    private static string ResolveTarget(string relativePath)
    {
        string normalized = relativePath.Replace('\\', '/');
        string appDir = GetAppDir();

        if (String.Equals(normalized, "version.json", StringComparison.OrdinalIgnoreCase))
        {
            return Path.Combine(appDir, "version.user.json");
        }

        if (normalized.StartsWith("app/", StringComparison.OrdinalIgnoreCase))
        {
            string remainder = normalized.Substring(4).Replace('/', Path.DirectorySeparatorChar);
            string target = Path.GetFullPath(Path.Combine(appDir, remainder));
            string trustedRoot = EnsureTrailingSeparator(Path.GetFullPath(appDir));

            if (!target.StartsWith(trustedRoot, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("App update path escapes Quick Repair directory.");
            }

            return target;
        }

        throw new InvalidDataException(
            "This updater only accepts user-level app files. Unsupported path: " + relativePath
        );
    }

    private static void ApplyTransaction(List<VerifiedFile> files, string version, long versionCode)
    {
        string appDir = GetAppDir();
        string rollbackDir = Path.Combine(appDir, "UpdateRollback");
        string pending = Path.Combine(appDir, "Update.pending");

        // A pending marker belongs to an older interrupted transaction. Main
        // must recover it before a new transaction is allowed to replace the
        // predecessor evidence.
        if (File.Exists(pending))
        {
            throw new UpdateRecoveryRequiredException();
        }

        if (Directory.Exists(rollbackDir))
        {
            Directory.Delete(rollbackDir, true);
        }

        Directory.CreateDirectory(rollbackDir);
        List<RollbackEntry> rollback = new List<RollbackEntry>();

        int index = 0;
        foreach (VerifiedFile file in files)
        {
            index++;
            bool existed = File.Exists(file.TargetPath);
            string backup = Path.Combine(rollbackDir, "file-" + index.ToString() + ".bak");

            if (existed)
            {
                File.Copy(file.TargetPath, backup, true);
            }

            RollbackEntry entry = new RollbackEntry();
            entry.Target = file.TargetPath;
            entry.Backup = backup;
            entry.Existed = existed;
            entry.RelativePath = file.RelativePath;
            entry.BackupSha256 = existed ? Sha256File(backup) : String.Empty;
            rollback.Add(entry);
        }

        File.WriteAllText(
            Path.Combine(rollbackDir, "rollback-map.json"),
            Json.Serialize(new Dictionary<string, object>
            {
                { "schema", 2 },
                { "version", version },
                { "versionCode", versionCode },
                { "createdUtc", DateTime.UtcNow.ToString("o") },
                { "files", rollback }
            }),
            new UTF8Encoding(false)
        );

        File.WriteAllText(pending, DateTime.UtcNow.ToString("o"), new UTF8Encoding(false));

        try
        {
            foreach (VerifiedFile file in files)
            {
                string parent = Path.GetDirectoryName(file.TargetPath);
                if (!String.IsNullOrEmpty(parent))
                {
                    Directory.CreateDirectory(parent);
                }

                string next = file.TargetPath + "." + Process.GetCurrentProcess().Id.ToString() + ".new";
                File.Copy(file.SourcePath, next, true);

                if (File.Exists(file.TargetPath))
                {
                    File.Delete(file.TargetPath);
                }

                File.Move(next, file.TargetPath);
            }

            foreach (VerifiedFile file in files)
            {
                if (!File.Exists(file.TargetPath) ||
                    !String.Equals(Sha256File(file.TargetPath), file.Sha256, StringComparison.OrdinalIgnoreCase))
                {
                    throw new IOException("Installed file verification failed.");
                }
            }

            if (File.Exists(pending))
            {
                File.Delete(pending);
            }
        }
        catch
        {
            bool restored = RestoreRollback(rollback);

            if (restored)
            {
                try
                {
                    if (File.Exists(pending))
                    {
                        File.Delete(pending);
                    }
                }
                catch
                {
                    restored = false;
                }
            }

            if (restored)
            {
                throw new UpdateRollbackException();
            }

            // Keep both Update.pending and UpdateRollback when restoration
            // cannot be verified. A later run may recover them; success is
            // never claimed merely because a copy operation was attempted.
            throw new UpdateRecoveryRequiredException();
        }
    }

    private static bool RestoreRollback(List<RollbackEntry> rollback)
    {
        bool restored = true;

        foreach (RollbackEntry entry in rollback)
        {
            try
            {
                if (entry.Existed)
                {
                    if (!File.Exists(entry.Backup))
                    {
                        restored = false;
                        continue;
                    }

                    string expected = entry.BackupSha256;
                    if (String.IsNullOrEmpty(expected))
                    {
                        expected = Sha256File(entry.Backup);
                    }

                    if (!IsSha256(expected) ||
                        !String.Equals(Sha256File(entry.Backup), expected, StringComparison.OrdinalIgnoreCase))
                    {
                        restored = false;
                        continue;
                    }

                    string parent = Path.GetDirectoryName(entry.Target);
                    if (!String.IsNullOrEmpty(parent))
                    {
                        Directory.CreateDirectory(parent);
                    }

                    File.Copy(entry.Backup, entry.Target, true);

                    if (!File.Exists(entry.Target) ||
                        !String.Equals(Sha256File(entry.Target), expected, StringComparison.OrdinalIgnoreCase))
                    {
                        restored = false;
                    }
                }
                else
                {
                    if (File.Exists(entry.Target))
                    {
                        File.Delete(entry.Target);
                    }

                    if (File.Exists(entry.Target))
                    {
                        restored = false;
                    }
                }
            }
            catch
            {
                restored = false;
            }
        }

        return restored;
    }

    private static bool RecoverInterruptedTransaction()
    {
        return RecoverInterruptedTransactionAt(GetAppDir());
    }

    // Private acceptance seam: production always supplies GetAppDir(). Tests
    // use a disposable root to prove old recovery records cannot escape it.
    private static bool RecoverInterruptedTransactionAt(string appDir)
    {
        appDir = Path.GetFullPath(appDir);
        string rollbackDir = Path.Combine(appDir, "UpdateRollback");
        string pending = Path.Combine(appDir, "Update.pending");
        string mapPath = Path.Combine(rollbackDir, "rollback-map.json");

        if (!File.Exists(pending))
        {
            return false;
        }

        try
        {
            if (HasReparsePointBetween(pending, appDir) ||
                !Directory.Exists(rollbackDir) ||
                HasReparsePointBetween(rollbackDir, appDir) ||
                !File.Exists(mapPath) ||
                HasReparsePointBetween(mapPath, appDir))
            {
                throw new InvalidDataException();
            }

            FileInfo mapInfo = new FileInfo(mapPath);
            if (mapInfo.Length <= 0 || mapInfo.Length > 65536)
            {
                throw new InvalidDataException();
            }

            Dictionary<string, object> root = DeserializeObject(File.ReadAllText(mapPath));
            long schema = root.ContainsKey("schema") ? ReadLong(root, "schema") : 1;
            if (schema != 1 && schema != 2)
            {
                throw new InvalidDataException();
            }

            object rawFiles;
            if (!root.TryGetValue("files", out rawFiles) || rawFiles == null)
            {
                throw new InvalidDataException();
            }

            IEnumerable sequence = rawFiles as IEnumerable;
            if (sequence == null || rawFiles is string)
            {
                throw new InvalidDataException();
            }

            List<RollbackEntry> rollback = new List<RollbackEntry>();
            HashSet<string> targets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            int index = 0;

            foreach (object raw in sequence)
            {
                Dictionary<string, object> item = raw as Dictionary<string, object>;
                if (item == null || ++index > 64)
                {
                    throw new InvalidDataException();
                }

                object existedValue;
                if (!item.TryGetValue("Existed", out existedValue) || !(existedValue is bool))
                {
                    throw new InvalidDataException();
                }

                string target = Path.GetFullPath(ReadString(item, "Target"));
                string backup = Path.GetFullPath(ReadString(item, "Backup"));
                string expectedBackup = Path.GetFullPath(
                    Path.Combine(rollbackDir, "file-" + index.ToString() + ".bak")
                );

                if (!IsPathWithin(target, appDir) ||
                    String.Equals(target, appDir, StringComparison.OrdinalIgnoreCase) ||
                    !String.Equals(backup, expectedBackup, StringComparison.OrdinalIgnoreCase) ||
                    HasReparsePointBetween(target, appDir) ||
                    HasReparsePointBetween(backup, rollbackDir) ||
                    !targets.Add(target))
                {
                    throw new InvalidDataException();
                }

                RollbackEntry entry = new RollbackEntry();
                entry.Target = target;
                entry.Backup = backup;
                entry.Existed = (bool)existedValue;
                entry.RelativePath = ReadString(item, "RelativePath");
                entry.BackupSha256 = ReadString(item, "BackupSha256");

                if (entry.Existed)
                {
                    if (!File.Exists(backup) || new FileInfo(backup).Length > 8388608)
                    {
                        throw new InvalidDataException();
                    }

                    string actualBackup = Sha256File(backup);
                    if (!String.IsNullOrEmpty(entry.BackupSha256) &&
                        (!IsSha256(entry.BackupSha256) ||
                         !String.Equals(actualBackup, entry.BackupSha256, StringComparison.OrdinalIgnoreCase)))
                    {
                        throw new InvalidDataException();
                    }

                    entry.BackupSha256 = actualBackup;
                }
                else if (File.Exists(backup))
                {
                    throw new InvalidDataException();
                }

                rollback.Add(entry);
            }

            if (rollback.Count == 0 || !RestoreRollback(rollback))
            {
                throw new InvalidDataException();
            }

            File.Delete(pending);
            return true;
        }
        catch (UpdateRecoveryRequiredException)
        {
            throw;
        }
        catch
        {
            throw new UpdateRecoveryRequiredException();
        }
    }

    private static bool IsPathWithin(string path, string root)
    {
        string fullPath = Path.GetFullPath(path);
        string fullRoot = EnsureTrailingSeparator(Path.GetFullPath(root));
        return fullPath.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase);
    }

    private static bool HasReparsePointBetween(string path, string root)
    {
        string fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
        string current = Path.GetFullPath(path);

        if (!IsPathWithin(current, fullRoot) &&
            !String.Equals(current, fullRoot, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        while (!String.IsNullOrEmpty(current))
        {
            if (File.Exists(current) || Directory.Exists(current))
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                {
                    return true;
                }
            }

            if (String.Equals(current.TrimEnd(Path.DirectorySeparatorChar), fullRoot, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            current = Path.GetDirectoryName(current);
        }

        return true;
    }

    private static void PreserveLocalPeerConfiguration()
    {
        string appDir = GetAppDir();
        string configPath = Path.Combine(appDir, "config.json");

        if (File.Exists(configPath))
        {
            return;
        }

        string peer = String.Empty;
        string uiPath = Path.Combine(appDir, "Tailscale-Repair-UI.ps1");

        if (File.Exists(uiPath))
        {
            try
            {
                string text = File.ReadAllText(uiPath);
                System.Text.RegularExpressions.Match match =
                    System.Text.RegularExpressions.Regex.Match(
                        text,
                        "(?m)^\\s*\\$Peer\\s*=\\s*['\\\"](?<peer>[^'\\\"\\r\\n]+)['\\\"]"
                    );

                if (match.Success)
                {
                    peer = match.Groups["peer"].Value.Trim();
                }
            }
            catch { }
        }

        if (String.IsNullOrWhiteSpace(peer))
        {
            string statePath = Path.Combine(appDir, "state.json");

            try
            {
                if (File.Exists(statePath))
                {
                    Dictionary<string, object> state = DeserializeObject(File.ReadAllText(statePath));

                    foreach (string name in new string[] { "peerIp", "peer", "targetPeer" })
                    {
                        string candidate = ReadString(state, name);
                        if (!String.IsNullOrWhiteSpace(candidate))
                        {
                            peer = candidate.Trim();
                            break;
                        }
                    }
                }
            }
            catch { }
        }

        if (String.IsNullOrWhiteSpace(peer) || peer.Length > 255 || peer.Contains("\r") || peer.Contains("\n"))
        {
            throw new InvalidDataException(
                "The existing remote peer could not be preserved safely. No update was applied."
            );
        }

        Directory.CreateDirectory(appDir);
        File.WriteAllText(
            configPath,
            Json.Serialize(new Dictionary<string, object> { { "peer", peer } }),
            new UTF8Encoding(false)
        );
    }

    private static void WaitForProcessExit(int pid, TimeSpan timeout)
    {
        try
        {
            using (Process process = Process.GetProcessById(pid))
            {
                if (!process.WaitForExit((int)timeout.TotalMilliseconds))
                {
                    throw new TimeoutException("Quick Repair did not close in time for the update.");
                }
            }
        }
        catch (ArgumentException)
        {
            // Already exited.
        }
    }

    private static void StartQuickRepair()
    {
        try
        {
            string appDir = GetAppDir();
            string exe = Path.Combine(appDir, "TailscaleQuickRepair.exe");

            if (File.Exists(exe))
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = exe,
                    UseShellExecute = true
                });
                return;
            }

            string launcher = Path.Combine(appDir, "Launch-Tailscale-Quick-Repair.vbs");
            if (File.Exists(launcher))
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "wscript.exe",
                    Arguments = Quote(launcher),
                    UseShellExecute = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                });
            }
        }
        catch { }
    }

    private static void WriteResult(
        bool success,
        string version,
        string outcome,
        string reason,
        bool recoveredPreviousTransaction
    )
    {
        string temporary = String.Empty;

        try
        {
            string appDir = GetAppDir();
            Directory.CreateDirectory(appDir);

            Dictionary<string, object> result = new Dictionary<string, object>();
            result["schema"] = 2;
            result["success"] = success;
            result["version"] = version ?? String.Empty;
            result["outcome"] = outcome ?? String.Empty;
            result["reason"] = reason ?? String.Empty;
            result["recoveredPrevious"] = recoveredPreviousTransaction;
            result["message"] = GetSafeResultMessage(
                outcome,
                reason,
                recoveredPreviousTransaction
            );
            result["completedUtc"] = DateTime.UtcNow.ToString("o");

            string path = Path.Combine(appDir, "update-result.json");
            temporary = path + "." + Process.GetCurrentProcess().Id.ToString() + ".tmp";

            File.WriteAllText(
                temporary,
                Json.Serialize(result),
                new UTF8Encoding(false)
            );

            if (File.Exists(path))
            {
                File.Replace(temporary, path, null, true);
            }
            else
            {
                File.Move(temporary, path);
            }
        }
        catch
        {
            try
            {
                if (!String.IsNullOrEmpty(temporary) && File.Exists(temporary))
                {
                    File.Delete(temporary);
                }
            }
            catch { }
        }
    }

    private static string GetFailureOutcome(Exception ex)
    {
        if (ex is UpdateRollbackException) return "rolled_back";
        if (ex is UpdateRecoveryRequiredException) return "recovery_required";
        return "failed";
    }

    private static string GetFailureReason(Exception ex)
    {
        if (ex is UpdateRollbackException) return "transaction_rolled_back";
        if (ex is UpdateRecoveryRequiredException) return "recovery_required";

        WebException web = ex as WebException;
        if (web != null)
        {
            if (IsTransientWebFailure(web)) return "transport_unavailable";

            HttpWebResponse response = web.Response as HttpWebResponse;
            if (response != null && (int)response.StatusCode == 404)
            {
                return "feed_or_package_unavailable";
            }

            return "network_refused";
        }

        if (ex is TimeoutException) return "transport_timeout";
        if (ex is InvalidDataException) return "integrity_refused";

        InvalidOperationException invalid = ex as InvalidOperationException;
        if (invalid != null &&
            invalid.Message != null &&
            invalid.Message.StartsWith("Another Quick Repair operation", StringComparison.Ordinal))
        {
            return "busy";
        }

        return "update_failed";
    }

    private static string GetSafeResultMessage(
        string outcome,
        string reason,
        bool recoveredPreviousTransaction
    )
    {
        string prefix = recoveredPreviousTransaction
            ? "A previous interrupted update was recovered safely. "
            : String.Empty;

        if (String.Equals(outcome, "rolled_back", StringComparison.Ordinal))
        {
            return prefix +
                "The update did not complete. The verified previous files were restored.";
        }

        if (String.Equals(outcome, "recovery_required", StringComparison.Ordinal))
        {
            return prefix +
                "The update could not complete and automatic recovery could not be verified. " +
                "Recovery data was kept.";
        }

        switch (reason)
        {
            case "integrity_refused":
                return prefix +
                    "The update was refused because its integrity or metadata could not be verified. " +
                    "No unverified update was installed.";
            case "transport_unavailable":
            case "transport_timeout":
                return prefix +
                    "The update download could not be completed. No update was installed.";
            case "feed_or_package_unavailable":
                return prefix +
                    "The selected update is not currently available. No update was installed.";
            case "busy":
                return prefix +
                    "Another Quick Repair operation is already running. No update was installed.";
            default:
                return prefix + "The update was not installed.";
        }
    }

    private static long ReadInstalledVersionCode()
    {
        try
        {
            string path = Path.Combine(GetAppDir(), "version.user.json");
            if (!File.Exists(path))
            {
                return 0;
            }

            Dictionary<string, object> data = DeserializeObject(File.ReadAllText(path));
            return ReadLong(data, "versionCode");
        }
        catch
        {
            return 0;
        }
    }

    private static string DownloadString(string url, bool githubApi)
    {
        return RunWithTransientRetry<string>(delegate
        {
            return DownloadStringOnce(url, githubApi);
        });
    }

    private static string DownloadStringOnce(string url, bool githubApi)
    {
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(url);
        request.Method = "GET";
        request.UserAgent = "TailscaleQuickRepairUpdater/3.0";
        request.Timeout = 12000;
        request.ReadWriteTimeout = 12000;
        request.Proxy = WebRequest.DefaultWebProxy;

        if (request.Proxy != null)
        {
            request.Proxy.Credentials = CredentialCache.DefaultNetworkCredentials;
        }

        if (githubApi)
        {
            request.Accept = "application/vnd.github+json";
            request.Headers["X-GitHub-Api-Version"] = "2022-11-28";
        }

        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        using (Stream stream = response.GetResponseStream())
        using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
        {
            return reader.ReadToEnd();
        }
    }

    private static void DownloadFile(string url, string destination)
    {
        if (!IsTrustedReleaseUrl(url))
        {
            throw new InvalidDataException("Refusing an untrusted update download URL.");
        }

        RunWithTransientRetry<bool>(delegate
        {
            try
            {
                if (File.Exists(destination))
                {
                    File.Delete(destination);
                }

                DownloadFileOnce(url, destination);
                return true;
            }
            catch
            {
                try
                {
                    if (File.Exists(destination))
                    {
                        File.Delete(destination);
                    }
                }
                catch { }

                throw;
            }
        });
    }

    private static void DownloadFileOnce(string url, string destination)
    {
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(url);
        request.Method = "GET";
        request.UserAgent = "TailscaleQuickRepairUpdater/3.0";
        request.Timeout = 30000;
        request.ReadWriteTimeout = 30000;
        request.AllowAutoRedirect = true;
        request.Proxy = WebRequest.DefaultWebProxy;

        if (request.Proxy != null)
        {
            request.Proxy.Credentials = CredentialCache.DefaultNetworkCredentials;
        }

        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        using (Stream input = response.GetResponseStream())
        using (FileStream output = File.Create(destination))
        {
            byte[] buffer = new byte[81920];
            int read;

            while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
            {
                output.Write(buffer, 0, read);
            }
        }
    }

    private static T RunWithTransientRetry<T>(Func<T> operation)
    {
        const int attempts = 3;

        for (int attempt = 1; attempt <= attempts; attempt++)
        {
            try
            {
                return operation();
            }
            catch (WebException ex)
            {
                if (attempt >= attempts || !IsTransientWebFailure(ex))
                {
                    throw;
                }

                Thread.Sleep(350 * attempt);
            }
        }

        throw new InvalidOperationException("Transient retry state is invalid.");
    }

    private static bool IsTransientWebFailure(WebException ex)
    {
        if (ex == null) return false;

        switch (ex.Status)
        {
            case WebExceptionStatus.Timeout:
            case WebExceptionStatus.ConnectFailure:
            case WebExceptionStatus.NameResolutionFailure:
            case WebExceptionStatus.ReceiveFailure:
            case WebExceptionStatus.SendFailure:
            case WebExceptionStatus.ConnectionClosed:
                return true;
            case WebExceptionStatus.ProtocolError:
                HttpWebResponse response = ex.Response as HttpWebResponse;
                return response != null && IsTransientStatusCode((int)response.StatusCode);
            default:
                return false;
        }
    }

    private static bool IsTransientStatusCode(int statusCode)
    {
        return statusCode == 408 ||
               statusCode == 429 ||
               (statusCode >= 500 && statusCode <= 599);
    }

    private static bool IsTrustedReleaseUrl(string value)
    {
        Uri uri;
        if (!Uri.TryCreate(value, UriKind.Absolute, out uri))
        {
            return false;
        }

        return String.Equals(uri.Scheme, "https", StringComparison.OrdinalIgnoreCase) &&
               String.Equals(uri.Host, TrustedHost, StringComparison.OrdinalIgnoreCase) &&
               uri.AbsolutePath.StartsWith(TrustedReleasePrefix, StringComparison.Ordinal);
    }

    private static string Sha256File(string path)
    {
        using (SHA256 sha = SHA256.Create())
        using (FileStream stream = File.OpenRead(path))
        {
            byte[] hash = sha.ComputeHash(stream);
            StringBuilder builder = new StringBuilder(hash.Length * 2);

            foreach (byte b in hash)
            {
                builder.Append(b.ToString("x2"));
            }

            return builder.ToString();
        }
    }

    private static bool IsSha256(string value)
    {
        if (String.IsNullOrEmpty(value) || value.Length != 64)
        {
            return false;
        }

        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            bool ok = (c >= '0' && c <= '9') ||
                      (c >= 'a' && c <= 'f') ||
                      (c >= 'A' && c <= 'F');
            if (!ok)
            {
                return false;
            }
        }

        return true;
    }

    private static Dictionary<string, object> DeserializeObject(string json)
    {
        Dictionary<string, object> value = Json.Deserialize<Dictionary<string, object>>(json);
        if (value == null)
        {
            throw new InvalidDataException("Invalid JSON response.");
        }

        return value;
    }

    private static Dictionary<string, object> ReadDictionary(
        Dictionary<string, object> source,
        string key
    )
    {
        object value;
        if (!source.TryGetValue(key, out value))
        {
            throw new InvalidDataException("Missing JSON object: " + key);
        }

        Dictionary<string, object> result = value as Dictionary<string, object>;
        if (result == null)
        {
            throw new InvalidDataException("Invalid JSON object: " + key);
        }

        return result;
    }

    private static string ReadString(Dictionary<string, object> source, string key)
    {
        object value;
        if (!source.TryGetValue(key, out value) || value == null)
        {
            return String.Empty;
        }

        return Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture) ?? String.Empty;
    }

    private static int ReadInt(Dictionary<string, object> source, string key)
    {
        return (int)ReadLong(source, key);
    }

    private static long ReadLong(Dictionary<string, object> source, string key)
    {
        object value;
        if (!source.TryGetValue(key, out value) || value == null)
        {
            return 0;
        }

        return Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture);
    }

    private static bool ReadBool(Dictionary<string, object> source, string key)
    {
        object value;
        if (!source.TryGetValue(key, out value) || value == null)
        {
            return false;
        }

        return Convert.ToBoolean(value, System.Globalization.CultureInfo.InvariantCulture);
    }

    private static bool HasSwitch(string[] args, string name)
    {
        foreach (string arg in args)
        {
            if (String.Equals(arg, name, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static int ReadIntArg(string[] args, string name, int fallback)
    {
        string value = ReadArg(args, name);
        int parsed;
        return Int32.TryParse(value, out parsed) ? parsed : fallback;
    }

    private static long ReadLongArg(string[] args, string name, long fallback)
    {
        string value = ReadArg(args, name);
        long parsed;
        return Int64.TryParse(value, out parsed) ? parsed : fallback;
    }

    private static string ReadArg(string[] args, string name)
    {
        for (int i = 0; i < args.Length - 1; i++)
        {
            if (String.Equals(args[i], name, StringComparison.OrdinalIgnoreCase))
            {
                return args[i + 1];
            }
        }

        return String.Empty;
    }

    private static string Quote(string value)
    {
        return "\"" + (value ?? String.Empty).Replace("\"", "\\\"") + "\"";
    }

    private static string GetAppDir()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "TailscaleQuickRepair"
        );
    }

    private static string EnsureTrailingSeparator(string path)
    {
        if (!path.EndsWith(Path.DirectorySeparatorChar.ToString(), StringComparison.Ordinal))
        {
            return path + Path.DirectorySeparatorChar;
        }

        return path;
    }

    private sealed class UpdateManifest
    {
        public bool Published;
        public bool RequiresSetup;
        public string Version = String.Empty;
        public long VersionCode;
        public string Notes = String.Empty;
        public string PackageUrl = String.Empty;
        public string PackageSha256 = String.Empty;
        public long PackageSize;
    }

    private sealed class PackageManifest
    {
        public string Version = String.Empty;
        public long VersionCode;
        public List<PackageFile> Files = new List<PackageFile>();
    }

    private sealed class PackageFile
    {
        public string Path = String.Empty;
        public string Sha256 = String.Empty;
        public long Size;
    }

    private sealed class VerifiedFile
    {
        public string RelativePath = String.Empty;
        public string SourcePath = String.Empty;
        public string TargetPath = String.Empty;
        public string Sha256 = String.Empty;
    }

    public sealed class RollbackEntry
    {
        public string Target = String.Empty;
        public string Backup = String.Empty;
        public bool Existed;
        public string RelativePath = String.Empty;
        public string BackupSha256 = String.Empty;
    }

    private sealed class UpdateRollbackException : IOException
    {
        public UpdateRollbackException()
            : base("The verified predecessor was restored.")
        {
        }
    }

    private sealed class UpdateRecoveryRequiredException : IOException
    {
        public UpdateRecoveryRequiredException()
            : base("Automatic update recovery could not be verified.")
        {
        }
    }
}
