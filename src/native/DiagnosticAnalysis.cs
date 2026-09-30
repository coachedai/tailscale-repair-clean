using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace Tqr
{
    public sealed class DiagnosticCommand
    {
        public int ExitCode = -1;
        public bool TimedOut;
        public bool Truncated;
        public string Output = "";
    }
    public sealed class DiagnosticProbe
    {
        public string Status = "Unknown";
        public string Path = "Unknown";
        public string Latency = "Unknown";
    }
    public sealed class DiagnosticNetwork
    {
        public string udp = "Unknown", ipv4 = "Unknown", ipv6 = "Unknown";
        public string nearestDerp = "Unknown", mapping = "Unknown", portMapping = "Unknown";
        public string status = "Incomplete";
    }
    public sealed class DiagnosticVerdict
    {
        public string Summary;
        public string Detail;
        public string Severity;
    }

    // This only interprets explicit probe evidence. It neither repairs a network
    // nor equates an online hint, relay, IPv6 absence or VPN installation with failure.
    public static class DiagnosticAnalysis
    {
        public static bool ValidPeer(string peer)
        {
            if (String.IsNullOrEmpty(peer) || peer.Length > 253 || peer != peer.Trim()) return false;
            IPAddress ip;
            if (IPAddress.TryParse(peer, out ip)) return peer.IndexOf('%') < 0;
            return Regex.IsMatch(peer, @"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.?$");
        }
        private static string Availability(string value)
        {
            if (Regex.IsMatch(value, @"^(true|yes)(?:\b|$)", RegexOptions.IgnoreCase)) return "Available";
            if (Regex.IsMatch(value, @"^(false|no)(?:\b|$)", RegexOptions.IgnoreCase)) return "Unavailable";
            return "Unknown";
        }
        public static DiagnosticNetwork ParseNetwork(DiagnosticCommand command)
        {
            DiagnosticNetwork value = new DiagnosticNetwork();
            if (command == null) return value;
            if (command.TimedOut) { value.status = "Timed out"; return value; }
            if (command.ExitCode != 0 || command.Truncated) return value;
            string text = command.Output ?? "";
            if (text.Length > 65536) return value;
            foreach (string raw in text.Split('\n'))
            {
                Match line = Regex.Match(raw.Trim(), @"^\*\s*(UDP|IPv4|IPv6|Nearest DERP|MappingVariesByDestIP|PortMapping):\s*(.*)$", RegexOptions.IgnoreCase);
                if (!line.Success) continue;
                string content = line.Groups[2].Value.Trim();
                switch (line.Groups[1].Value.ToLowerInvariant())
                {
                    case "udp": value.udp = Availability(content); break;
                    case "ipv4": value.ipv4 = Availability(content); break;
                    case "ipv6": value.ipv6 = Availability(content); break;
                    case "nearest derp":
                        if (Regex.IsMatch(content, @"^[A-Za-z][A-Za-z ()-]{0,47}$")) value.nearestDerp = content;
                        break;
                    case "mappingvariesbydestip":
                        if (content == "true") value.mapping = "Varies by destination";
                        else if (content == "false") value.mapping = "Stable mapping";
                        break;
                    case "portmapping":
                        List<string> names = new List<string>();
                        foreach (string name in new string[] { "UPnP", "NAT-PMP", "PCP" })
                            if (Regex.IsMatch(content, @"\b" + name + @"\b", RegexOptions.IgnoreCase)) names.Add(name);
                        value.portMapping = names.Count > 0 ? String.Join(", ", names.ToArray()) :
                            (content.Length == 0 ? "None detected" : "Unknown");
                        break;
                }
            }
            value.status = value.udp != "Unknown" && value.ipv4 != "Unknown" && value.ipv6 != "Unknown" ? "Complete" : "Incomplete";
            return value;
        }
        private static string PathType(string via)
        {
            Match derp = Regex.Match(via, @"^DERP\(([A-Za-z0-9_-]{1,24})\)$", RegexOptions.IgnoreCase);
            if (derp.Success) return "Relay / " + derp.Groups[1].Value.ToUpperInvariant();
            if (Regex.IsMatch(via, @"^peer-relay\([^\r\n]{1,128}\)$", RegexOptions.IgnoreCase)) return "Peer relay";
            if (via.Equals("direct", StringComparison.OrdinalIgnoreCase)) return "Direct";
            Match endpoint = Regex.Match(via, @"^(?:\[(?<ip>[0-9a-fA-F:]+)\]|(?<ip>\d{1,3}(?:\.\d{1,3}){3})):(?<port>\d{1,5})$");
            IPAddress ip; int port;
            if (endpoint.Success && IPAddress.TryParse(endpoint.Groups["ip"].Value, out ip) &&
                Int32.TryParse(endpoint.Groups["port"].Value, out port) && port > 0 && port <= 65535) return "Direct";
            return "Unknown";
        }
        public static DiagnosticProbe ParseProbe(DiagnosticCommand command, string type)
        {
            DiagnosticProbe result = new DiagnosticProbe();
            if (command == null) return result;
            if (command.TimedOut) { result.Status = "Timed out"; return result; }
            string text = command.Output ?? "";
            if (command.Truncated || text.Length > 65536) { result.Status = "Incomplete"; return result; }
            if (Regex.IsMatch(text, @"(?i)unknown flag|flag provided but not defined|unsupported flag"))
            { result.Status = "Not supported"; return result; }
            if (command.ExitCode != 0)
            {
                result.Status = Regex.IsMatch(text, @"(?i)timeout|timed out|no reply|no response") ? "Timed out" : "Not confirmed";
                return result;
            }
            foreach (string raw in text.Split('\n'))
            {
                string line = raw.Trim();
                Match reply = Regex.Match(line, @"^pong from .+ via (?<via>.+) in (?<ms>\d+(?:\.\d+)?)\s*ms$", RegexOptions.IgnoreCase);
                if (type == "peerapi") reply = Regex.Match(line, @"^hit peerapi of .+ in (?<ms>\d+(?:\.\d+)?)\s*ms$", RegexOptions.IgnoreCase);
                if (!reply.Success) continue;
                if (type == "tsmp" && !reply.Groups["via"].Value.Equals("TSMP", StringComparison.OrdinalIgnoreCase)) continue;
                if (type == "icmp" && !reply.Groups["via"].Value.Equals("ICMP", StringComparison.OrdinalIgnoreCase)) continue;
                double latency;
                if (!Double.TryParse(reply.Groups["ms"].Value, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out latency) || latency < 0 || latency > 600000) continue;
                result.Status = "Reachable";
                result.Latency = Math.Round(latency).ToString(CultureInfo.InvariantCulture) + " ms";
                if (type == "disco") result.Path = PathType(reply.Groups["via"].Value);
            }
            return result;
        }
        public static DiagnosticVerdict Explain(DiagnosticNetwork net, DiagnosticProbe disco, DiagnosticProbe tunnel, DiagnosticProbe icmp, DiagnosticProbe api)
        {
            string summary, detail; string severity = "info";
            if (disco.Status != "Reachable" && tunnel.Status != "Reachable")
            {
                summary = "The peer connection was not confirmed by these probes.";
                detail = "The peer may be offline or a probe may be blocked. These results do not identify the cause.";
                severity = "warn";
            }
            else if (tunnel.Status != "Reachable")
            {
                summary = "Discovery answered; the tunnel probe was not confirmed.";
                detail = "A discovery reply does not verify every layer. Review the Tunnel result before assuming the remote application works.";
                severity = "warn";
            }
            else if (disco.Path == "Unknown")
            {
                summary = "The tunnel answered; its path was not identified.";
                detail = "No direct or relay path is inferred from another check. Unknown means this probe did not establish it.";
            }
            else if (net.udp == "Unavailable")
            {
                summary = "Peer reachable; UDP was unavailable in this network check.";
                detail = "The replies are valid observations. UDP availability and the peer path are separate tests; no firewall or VPN changes were made.";
                severity = "warn";
            }
            else if (disco.Path.StartsWith("Relay") || disco.Path == "Peer relay")
            {
                summary = "Peer reachable through " + (disco.Path == "Peer relay" ? "a peer relay." : "a DERP relay.");
                detail = "A relay is a working connection, not a failure. This single probe did not observe a direct path.";
            }
            else if (icmp.Status != "Reachable")
            {
                summary = "Direct tunnel confirmed; ICMP was not confirmed.";
                detail = "ICMP can be blocked independently. Its result alone does not prove that the remote application is unavailable.";
            }
            else if (api.Status != "Reachable")
            {
                summary = "Direct tunnel confirmed; Peer API was not confirmed.";
                detail = "Peer API checks a Tailscale feature endpoint, not your RDP service. Failure here is not by itself a broken tunnel.";
            }
            else if (net.status != "Complete")
            {
                summary = "Peer probes answered; the network inspection is incomplete.";
                detail = "The available peer replies are shown below. Missing network measurements are not treated as successful checks.";
            }
            else
            {
                summary = "Direct path and tunnel replies confirmed.";
                detail = "All four peer probes answered. IPv6 absence alone is not an error when the measured connection works.";
                severity = "good";
            }
            return new DiagnosticVerdict { Summary = summary, Detail = detail + " This is a point-in-time probe, not a bandwidth or RDP test.", Severity = severity };
        }

        // Only these fixed commands are supported. No shell, stdin or arbitrary
        // switches. Output retention and runtime are bounded; raw output stays in RAM.
        public static DiagnosticCommand Run(string executable, string type, string peer, int timeoutMs)
        {
            DiagnosticCommand result = new DiagnosticCommand();
            if (timeoutMs < 100 || timeoutMs > 10000 || !ValidPeer(peer)) return result;
            string arguments;
            switch (type)
            {
                case "netcheck": arguments = "netcheck"; break;
                case "disco": arguments = "ping --until-direct=false --c=1 --timeout=2s "; break;
                case "tsmp": arguments = "ping --tsmp --c=1 --timeout=2s "; break;
                case "icmp": arguments = "ping --icmp --c=1 --timeout=2s "; break;
                case "peerapi": arguments = "ping --peerapi --c=1 --timeout=2s "; break;
                default: return result;
            }
            if (type != "netcheck") arguments += "\"" + peer + "\"";
            object sync = new object(); StringBuilder captured = new StringBuilder(); bool clipped = false; int completedReaders = 0;
            using (Process process = new Process())
            {
                process.StartInfo = new ProcessStartInfo(executable, arguments) { UseShellExecute = false, CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden, RedirectStandardOutput = true, RedirectStandardError = true };
                DataReceivedEventHandler collect = delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data == null) { Interlocked.Increment(ref completedReaders); return; }
                    lock (sync)
                    {
                        int remaining = 65536 - captured.Length;
                        if (e.Data.Length + 1 > remaining) clipped = true;
                        if (remaining > 0) captured.Append(e.Data.Substring(0, Math.Min(e.Data.Length, remaining)));
                        if (captured.Length < 65536) captured.Append('\n');
                    }
                };
                process.OutputDataReceived += collect; process.ErrorDataReceived += collect;
                try
                {
                    if (!process.Start()) return result;
                    process.BeginOutputReadLine(); process.BeginErrorReadLine();
                    if (!process.WaitForExit(timeoutMs))
                    {
                        result.TimedOut = true;
                        process.Kill(); // Only the exact child created by this call.
                        if (!process.WaitForExit(1000)) return result;
                    }
                    else
                    {
                        Stopwatch drain = Stopwatch.StartNew();
                        while (Interlocked.CompareExchange(ref completedReaders, 0, 0) < 2 && drain.ElapsedMilliseconds < 500) Thread.Sleep(5);
                        if (Interlocked.CompareExchange(ref completedReaders, 0, 0) < 2) clipped = true;
                    }
                    result.ExitCode = process.ExitCode;
                }
                catch { result.ExitCode = -1; }
                finally
                {
                    try { if (!process.HasExited) { process.Kill(); process.WaitForExit(1000); } } catch { }
                    lock (sync) { result.Output = captured.ToString(); result.Truncated = clipped; }
                }
            }
            return result;
        }
    }
}
