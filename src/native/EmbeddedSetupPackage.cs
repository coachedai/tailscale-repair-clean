using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace Tqr
{
    // The standalone installer reads only its own resources, never a sibling ZIP.
    internal sealed class EmbeddedSetupPackage
    {
        internal const string Repository = "coachedai/tailscale-repair-clean";
        internal const long RepositoryId = 1398720044;
        private const long MaximumSize = 64 * 1024 * 1024;
        internal string Version;
        internal long VersionCode;
        internal string Sha256;
        internal long Size;
        internal string Channel;

        internal static EmbeddedSetupPackage Read()
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream metadata = assembly.GetManifestResourceStream("Tqr.SetupMetadata"))
            using (Stream payload = assembly.GetManifestResourceStream("Tqr.SetupPayload"))
            {
                if (metadata == null && payload == null) return null;
                if (metadata == null || payload == null || metadata.Length < 1 || metadata.Length > 4096)
                    throw new InvalidDataException("The embedded Setup metadata is invalid.");
                string json;
                using (StreamReader reader = new StreamReader(metadata, new UTF8Encoding(false, true)))
                    json = reader.ReadToEnd();
                EmbeddedSetupPackage result = ParseMetadata(json);
                if (payload.Length != result.Size)
                    throw new InvalidDataException("The embedded Setup package size is invalid.");
                return result;
            }
        }

        internal static EmbeddedSetupPackage ParseMetadata(string json)
        {
            if (String.IsNullOrWhiteSpace(json) || json.Length > 4096)
                throw new InvalidDataException("The embedded Setup metadata is invalid.");
            JavaScriptSerializer parser = new JavaScriptSerializer();
            parser.MaxJsonLength = 4096;
            Dictionary<string, object> data = parser.DeserializeObject(json) as Dictionary<string, object>;
            string[] keys = { "schema", "repository", "repositoryId", "version", "versionCode", "sha256", "size", "channel" };
            if (data == null || data.Count != keys.Length)
                throw new InvalidDataException("The embedded Setup metadata is invalid.");
            foreach (string key in keys)
                if (!data.ContainsKey(key)) throw new InvalidDataException("The embedded Setup metadata is incomplete.");
            if (Number(data["schema"]) != 1 || !(data["repository"] is string) ||
                (string)data["repository"] != Repository || Number(data["repositoryId"]) != RepositoryId)
                throw new InvalidDataException("The embedded Setup repository identity is invalid.");
            EmbeddedSetupPackage result = new EmbeddedSetupPackage();
            result.Version = data["version"] as string;
            result.VersionCode = Number(data["versionCode"]);
            result.Sha256 = data["sha256"] as string;
            result.Size = Number(data["size"]);
            result.Channel = data["channel"] as string;
            if (result.Version == null || !Regex.IsMatch(result.Version, @"\A[0-9A-Za-z][0-9A-Za-z.+-]{0,79}\z") ||
                result.VersionCode <= 0 || result.Size <= 0 || result.Size > MaximumSize ||
                result.Sha256 == null || !Regex.IsMatch(result.Sha256, @"\A[a-f0-9]{64}\z") ||
                (result.Channel != "stable" && result.Channel != "preview"))
                throw new InvalidDataException("The embedded Setup package metadata is invalid.");
            return result;
        }

        private static long Number(object value)
        {
            if (value is int) return (int)value;
            if (value is long) return (long)value;
            throw new InvalidDataException("The embedded Setup metadata contains an invalid number.");
        }

        internal void RequireTarget(long requested)
        {
            if (requested < 0 || (requested > 0 && requested != VersionCode))
                throw new InvalidDataException("This installer does not match the selected version.");
        }

        internal static bool HasExistingInstallation(string appDirectory)
        {
            foreach (string leaf in new string[] { "config.json", "version.user.json", "TailscaleQuickRepair.exe" })
            {
                string path = Path.Combine(appDirectory, leaf);
                if (!File.Exists(path)) continue;
                if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Existing installation metadata requires review.");
                return true;
            }
            return false;
        }

        internal void RefuseDowngrade(string appDirectory)
        {
            string path = Path.Combine(appDirectory, "version.user.json");
            if (!File.Exists(path)) return;
            FileInfo info = new FileInfo(path);
            if ((info.Attributes & FileAttributes.ReparsePoint) != 0 || info.Length > 4096)
                throw new InvalidDataException("The installed version could not be verified.");
            Dictionary<string, object> data = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
            object value;
            if (data == null || !data.TryGetValue("versionCode", out value) || Number(value) <= 0)
                throw new InvalidDataException("The installed version could not be verified.");
            if (Number(value) > VersionCode)
                throw new InvalidDataException("A newer version is installed. Setup will not downgrade it.");
        }

        internal void CopyTo(string destination)
        {
            using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream("Tqr.SetupPayload"))
            {
                if (input == null || input.Length != Size)
                    throw new InvalidDataException("The embedded Setup package is missing.");
                CopyVerified(input, destination, Size, Sha256);
            }
        }

        internal static void CopyVerified(Stream input, string destination, long size, string expectedHash)
        {
            if (input == null || size <= 0 || size > MaximumSize || expectedHash == null || !Regex.IsMatch(expectedHash, @"\A[a-f0-9]{64}\z"))
                throw new InvalidDataException("The embedded Setup package is invalid.");
            // CreateNew prevents replacement of an existing staging file.
            using (FileStream output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (SHA256 hash = SHA256.Create())
            {
                byte[] buffer = new byte[65536];
                long total = 0;
                int count;
                while ((count = input.Read(buffer, 0, buffer.Length)) > 0)
                {
                    total += count;
                    if (total > size) throw new InvalidDataException("The embedded Setup package is too large.");
                    hash.TransformBlock(buffer, 0, count, buffer, 0);
                    output.Write(buffer, 0, count);
                }
                hash.TransformFinalBlock(new byte[0], 0, 0);
                string actual = BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant();
                if (total != size || !String.Equals(actual, expectedHash, StringComparison.Ordinal))
                    throw new InvalidDataException("The embedded Setup package failed SHA-256 verification.");
                output.Flush(true);
            }
        }
    }
}
