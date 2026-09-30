using System;
using System.Collections.Generic;
using System.Net.NetworkInformation;

namespace Tqr
{
    public sealed class VpnSnapshot
    {
        public string State = "Unknown";
        public string Label = "";
        public string Signature = "";
        public int ActiveCount;
    }

    public static class VpnAwareness
    {
        private static bool Has(string value, string token)
        {
            return value.IndexOf(token, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static string Combined(string name, string description)
        {
            return ((name ?? "") + " " + (description ?? "")).Trim();
        }

        // Pure classifier used by tests and by the live read-only adapter scan.
        // It returns only fixed labels; raw adapter names/descriptions never leave
        // this boundary.
        public static string Classify(
            string name,
            string description,
            NetworkInterfaceType type,
            OperationalStatus status)
        {
            if (status != OperationalStatus.Up) return "";

            string value = Combined(name, description);
            if (String.IsNullOrWhiteSpace(value) || Has(value, "tailscale")) return "";

            if (Has(value, "proton vpn") || Has(value, "protonvpn")) return "Proton VPN";
            if (Has(value, "nordvpn") || Has(value, "nord vpn")) return "NordVPN";
            if (Has(value, "mullvad")) return "Mullvad";
            if (Has(value, "expressvpn") || Has(value, "express vpn")) return "ExpressVPN";
            if (Has(value, "surfshark")) return "Surfshark";
            if (Has(value, "private internet access") || Has(value, "pia tunnel") ||
                Has(value, "pia client") || Has(value, "pia-service")) return "Private Internet Access";
            if (Has(value, "windscribe")) return "Windscribe";
            if (Has(value, "ivpn")) return "IVPN";
            if (Has(value, "tunnelbear")) return "TunnelBear";
            if (Has(value, "cyberghost")) return "CyberGhost";
            if (Has(value, "cloudflare warp") || Has(value, "cloudflarewarp")) return "Cloudflare WARP";
            if (Has(value, "mozilla vpn")) return "Mozilla VPN";
            if (Has(value, "hide.me") || Has(value, "hideme vpn")) return "hide.me";
            if (Has(value, "purevpn") || Has(value, "pure vpn")) return "PureVPN";
            if (Has(value, "hotspot shield") || Has(value, "hotspotshield")) return "Hotspot Shield";
            if (Has(value, "cisco secure client") || Has(value, "anyconnect") ||
                Has(value, "vpnagent")) return "Cisco Secure Client";
            if (Has(value, "globalprotect") || Has(value, "pangp")) return "GlobalProtect";
            if (Has(value, "forticlient") || Has(value, "fortinet vpn")) return "FortiClient VPN";
            if (Has(value, "ivanti secure access") || Has(value, "pulse secure") ||
                Has(value, "pulsesecure")) return "Ivanti Secure Access";
            if (Has(value, "openvpn")) return "OpenVPN";
            if (Has(value, "wireguard")) return "WireGuard";

            if (type == NetworkInterfaceType.Tunnel || type == NetworkInterfaceType.Ppp ||
                Has(value, "wintun") || Has(value, "tap-windows") ||
                Has(value, "vpn adapter") || Has(value, "vpn tunnel"))
                return "VPN tunnel";

            return "";
        }

        public static VpnSnapshot Inspect()
        {
            VpnSnapshot result = new VpnSnapshot();

            try
            {
                HashSet<string> labels = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                int active = 0;

                foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    string label = Classify(nic.Name, nic.Description, nic.NetworkInterfaceType, nic.OperationalStatus);
                    if (String.IsNullOrEmpty(label)) continue;
                    active++;
                    labels.Add(label);
                }

                if (active == 0)
                {
                    result.State = "NotDetected";
                    result.Signature = "NotDetected";
                    return result;
                }

                List<string> ordered = new List<string>(labels);
                ordered.Sort(StringComparer.OrdinalIgnoreCase);
                result.State = "Detected";
                result.ActiveCount = active;
                result.Label = ordered.Count == 1 ? ordered[0] : "Multiple VPNs";
                result.Signature = "Detected|" + String.Join(",", ordered.ToArray()) + "|" + active.ToString();
                return result;
            }
            catch
            {
                result.State = "Unknown";
                result.Label = "";
                result.Signature = "";
                result.ActiveCount = 0;
                return result;
            }
        }
    }
}
