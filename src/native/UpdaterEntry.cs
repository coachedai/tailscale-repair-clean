using System;
using System.IO;
using System.Net;
using System.Reflection;
using System.Text;
using System.Threading;

internal static class UpdaterEntry
{

    [STAThread]
    private static int Main(string[] args)
    {
        ConfigureTls12();

        if (HasSwitch(args, "--network-self-test"))
        {
            try
            {
                string channel = Program.NormalizeChannel(ReadArg(args, "--channel"));
                return RunNetworkSelfTest(channel);
            }
            catch (InvalidDataException)
            {
                return 26;
            }
        }

        try
        {
            MethodInfo main = typeof(Program).GetMethod(
                "Main",
                BindingFlags.Static | BindingFlags.NonPublic
            );

            if (main == null)
            {
                return 11;
            }

            object result = main.Invoke(null, new object[] { args });
            return result is int ? (int)result : 12;
        }
        catch (TargetInvocationException ex)
        {
            Exception inner = ex.InnerException ?? ex;

            try
            {
                File.WriteAllText(
                    Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        "TailscaleQuickRepair",
                        "native-updater-entry-error.txt"
                    ),
                    inner.Message,
                    new UTF8Encoding(false)
                );
            }
            catch { }

            return 13;
        }
        catch
        {
            return 14;
        }
    }

    private static void ConfigureTls12()
    {
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
        ServicePointManager.Expect100Continue = false;
    }

    private static int RunNetworkSelfTest(string channel)
    {
        bool rateLimited;
        int result = RunNetworkSelfTestCore(channel, null, out rateLimited);

        if (result == 0 || result == 25 || !rateLimited)
        {
            return result;
        }

        // GitHub-hosted runners share outbound API capacity. Always exercise
        // the real unauthenticated product request first. Only when GitHub
        // explicitly identifies rate limiting may CI repeat the same endpoint
        // with its read-only Actions token. TLS/trust failures never fall back.
        string token = Environment.GetEnvironmentVariable("TQR_UPDATER_SELFTEST_TOKEN");
        if (String.IsNullOrWhiteSpace(token))
        {
            return result;
        }

        bool authenticatedRateLimit;
        return RunNetworkSelfTestCore(channel, token.Trim(), out authenticatedRateLimit);
    }

    private static int RunNetworkSelfTestCore(string channel, string bearerToken, out bool rateLimited)
    {
        int lastFailure = 24;
        string networkTestUrl = Program.GetManifestApiUrl(channel);
        bool endpointWasReachable = false;
        rateLimited = false;

        for (int attempt = 1; attempt <= 3; attempt++)
        {
            try
            {
                ConfigureTls12();

                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(networkTestUrl);
                request.Method = "GET";
                request.UserAgent = "TailscaleQuickRepairUpdater-SelfTest/3.0";
                request.Accept = "application/vnd.github+json";
                request.Headers["X-GitHub-Api-Version"] = "2022-11-28";
                if (!String.IsNullOrWhiteSpace(bearerToken))
                {
                    request.Headers["Authorization"] = "Bearer " + bearerToken;
                }
                request.Timeout = 12000;
                request.ReadWriteTimeout = 12000;
                request.Proxy = WebRequest.DefaultWebProxy;

                if (request.Proxy != null)
                {
                    request.Proxy.Credentials = CredentialCache.DefaultNetworkCredentials;
                }

                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                {
                    endpointWasReachable = true;

                    if (response.StatusCode != HttpStatusCode.OK)
                    {
                        lastFailure = 21;
                    }
                    else if (response.ResponseUri == null ||
                        !String.Equals(
                            response.ResponseUri.Scheme,
                            "https",
                            StringComparison.OrdinalIgnoreCase
                        ) ||
                        !String.Equals(
                            response.ResponseUri.Host,
                            "api.github.com",
                            StringComparison.OrdinalIgnoreCase
                        ))
                    {
                        lastFailure = 22;
                    }
                    else
                    {
                        using (Stream stream = response.GetResponseStream())
                        using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
                        {
                            string body = reader.ReadToEnd();

                            if (!String.IsNullOrWhiteSpace(body) &&
                                body.IndexOf("\"encoding\"", StringComparison.OrdinalIgnoreCase) >= 0)
                            {
                                return 0;
                            }

                            lastFailure = 23;
                        }
                    }
                }
            }
            catch (WebException ex)
            {
                if (
                    ex.Status == WebExceptionStatus.SecureChannelFailure ||
                    ex.Status == WebExceptionStatus.TrustFailure
                )
                {
                    // A real TLS/certificate regression is always release-blocking.
                    return 25;
                }

                if (ex.Status == WebExceptionStatus.ProtocolError)
                {
                    endpointWasReachable = true;
                    HttpWebResponse response = ex.Response as HttpWebResponse;
                    try
                    {
                        if (response != null)
                        {
                            int status = (int)response.StatusCode;
                            string remaining = response.Headers["X-RateLimit-Remaining"];
                            string retryAfter = response.Headers["Retry-After"];
                            bool explicitRateLimit =
                                status == 429 ||
                                (status == 403 &&
                                    (String.Equals(remaining, "0", StringComparison.Ordinal) ||
                                     !String.IsNullOrWhiteSpace(retryAfter)));

                            if (explicitRateLimit)
                            {
                                rateLimited = true;
                                return 26;
                            }
                        }

                        // GitHub answered, but not with an identified rate-limit
                        // response. Preserve the hard protocol failure.
                        lastFailure = 21;
                    }
                    finally
                    {
                        if (response != null) response.Dispose();
                    }
                }
                else
                {
                    lastFailure = 24;
                }
            }
            catch
            {
                lastFailure = 24;
            }

            if (attempt < 3)
            {
                Thread.Sleep(attempt * 1000);
            }
        }

        // A missing response cannot establish public update availability.
        // Keep DNS, connection and protocol failures release-blocking.
        return lastFailure;
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
}
