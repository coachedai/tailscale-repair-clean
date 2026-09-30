using System;

namespace Tqr
{
    public sealed class PassiveStartupObservation
    {
        public bool AppFilesReady;
        public bool EngineReady;
        public string Config = "Unknown";
        public string Service = "Unknown";
        public string Startup = "Unknown";
        public string Client = "Unknown";
        public string Backend = "Unknown";
        public string LocalIp = "";
        public string Version = "";
    }

    public sealed class PassiveStartupDecision
    {
        public string Status = "Waiting";
        public string Reason = "unconfirmed";
        public string Title = "Local status is not confirmed";
        public string Detail = "Passive health did not change anything.";
        public string NotificationCode = "";
        public bool LocalHealthy;
    }

    // Pure local-startup policy. No network, filesystem, process, service,
    // repair, timer, peer, route, latency or persistence access belongs here.
    public static class PassiveStartupHealth
    {
        private static bool In(string value, params string[] choices)
        { return Array.IndexOf(choices, value) >= 0; }

        private static PassiveStartupDecision D(
            string status, string reason, string title, string detail,
            string notification, bool healthy)
        {
            return new PassiveStartupDecision {
                Status=status, Reason=reason, Title=title, Detail=detail,
                NotificationCode=notification, LocalHealthy=healthy
            };
        }

        public static PassiveStartupDecision Evaluate(PassiveStartupObservation o)
        {
            if (o == null) return D("Waiting","unconfirmed","Local status is not confirmed",
                "Passive health did not change anything.","",false);

            if (!o.AppFilesReady || !o.EngineReady)
                return D("Attention","quick_repair_maintenance","Quick Repair needs maintenance",
                    "Quick Repair's local installation needs maintenance before health can be trusted.",
                    "startup_maintenance",false);

            if (!In(o.Config,"Missing","Configured","Invalid","Unknown") ||
                !In(o.Service,"Missing","Stopped","Running","Unknown") ||
                !In(o.Startup,"Automatic","Manual","Disabled","Unknown") ||
                !In(o.Client,"Running","Closed","Unknown") ||
                !In(o.Backend,"NoState","InUseOtherUser","NeedsLogin","NeedsMachineAuth","Stopped","Starting","Running","Unknown"))
                return D("Waiting","unconfirmed","Local status is not confirmed",
                    "Passive health received an unrecognised local state and changed nothing.","",false);

            if (o.Config == "Invalid")
                return D("Attention","config_attention","Quick Repair target needs attention",
                    "The local target configuration could not be validated. No network check was started.",
                    "startup_config_attention",false);

            if (o.Service == "Missing")
                return D("Attention","installation_missing","Tailscale is unavailable",
                    "Tailscale is not installed or its Windows service is missing.",
                    "startup_tailscale_missing",false);

            if (o.Startup == "Disabled")
                return D("Attention","service_disabled","Tailscale service is disabled",
                    "The Tailscale service is disabled. Quick Repair left it unchanged.",
                    "startup_service_disabled",false);

            if (o.Backend == "NeedsLogin")
                return D("Attention","sign_in","Tailscale sign-in needed",
                    "Tailscale needs sign-in. Quick Repair left it unchanged.",
                    "startup_sign_in",false);

            if (o.Backend == "NeedsMachineAuth")
                return D("Attention","approval","Tailscale approval needed",
                    "This Tailscale device needs approval. Quick Repair left it unchanged.",
                    "startup_approval",false);

            if (o.Backend == "InUseOtherUser")
                return D("Attention","other_user","Tailscale is active for another user",
                    "Another Windows user is using Tailscale. Quick Repair left it unchanged.",
                    "startup_other_user",false);

            if (o.Backend == "Stopped")
                return D("Paused","disconnected","Tailscale is disconnected",
                    "Quick Repair preserved the intentional local disconnect and did not start a repair.",
                    "",false);

            if (o.Service == "Stopped")
                return D("Waiting","service_stopped","Tailscale service is stopped",
                    "Passive health did not start or restart the service.","",false);

            if (o.Service != "Running" || o.Startup == "Unknown")
                return D("Waiting","unconfirmed","Local Tailscale is not confirmed",
                    "Passive health could not confirm the local service state and changed nothing.","",false);

            if (o.Backend == "Starting" || o.Backend == "NoState" || o.Backend == "Unknown")
                return D("Waiting","backend_settling","Local Tailscale is settling",
                    "The local backend is not ready yet. Passive health will not force a change.","",false);

            if (o.Backend == "Running" && o.Client == "Closed")
                return D("Waiting","client_closed","Tailscale service is running",
                    "The desktop client is closed. Passive health did not reopen it.","",false);

            if (o.Backend == "Running" && o.Client == "Running")
            {
                if (o.Config == "Missing")
                    return D("Healthy","local_healthy_target_missing","Local Tailscale is healthy",
                        "Choose a target when you want to run a connection check.","",true);
                if (o.Config == "Configured")
                    return D("Healthy","local_healthy","Local Tailscale is healthy",
                        "Local service, client and backend are running. No peer check was performed.","",true);
            }

            return D("Waiting","unconfirmed","Local status is not confirmed",
                "Passive health did not change anything.","",false);
        }
    }
}