using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Tqr
{
    public sealed class ConnectionQualityView
    {
        public string Summary = "";
        public string Baseline = "Not measured";
        public string Explanation = "";
        public string Tone = "muted";
        public string EventText = "";
        public string EventCode = "";
        public int Before = -1;
        public int After = -1;
        public int ComparableCount;
        public int CheckCount;
        public int RouteChanges;
        public double Median = Double.NaN;
    }

    // Observation analysis only: no network calls, files, timers or repair actions.
    // All samples and the target key live in this app session, at most 20 results.
    public sealed class ConnectionQuality
    {
        private sealed class Sample
        {
            public DateTime Time;
            public string Route;
            public string RouteClass;
            public string Status;
            public double Latency;
            public bool Baseline;
            public int Direction;
            public int Streak;
        }
        private readonly List<Sample> samples = new List<Sample>();
        private string target = "";
        private DateTime lastStamp = DateTime.MinValue;
        private DateTime notBefore = DateTime.MinValue;
        public int Count { get { return samples.Count; } }

        public void Reset(DateTime nowUtc)
        {
            samples.Clear();
            target = "";
            lastStamp = DateTime.MinValue;
            notBefore = nowUtc.ToUniversalTime();
        }

        public static double ParseLatency(string value)
        {
            if (value == null || value.Length > 32 ||
                !Regex.IsMatch(value, @"^\d+(?:\.\d+)?\s*ms$", RegexOptions.CultureInvariant))
                return Double.NaN;
            string numeric = value.Substring(0, value.Length - 2).Trim();
            double parsed;
            return Double.TryParse(numeric, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out parsed)
                && parsed >= 0 && parsed <= 600000 ? parsed : Double.NaN;
        }

        private static string RouteClass(string route)
        {
            if (String.IsNullOrWhiteSpace(route) || route.Length > 128) return "Unknown";
            if (String.Equals(route, "Direct", StringComparison.OrdinalIgnoreCase)) return "Direct";
            if (route.StartsWith("Peer relay", StringComparison.OrdinalIgnoreCase) ||
                route.StartsWith("Peer-relay", StringComparison.OrdinalIgnoreCase)) return "Peer relay";
            if (Regex.IsMatch(route, @"^Relay(?:\s*[\u00b7-]\s*[A-Za-z0-9_-]{1,24})?$", RegexOptions.IgnoreCase)) return "Relay";
            return "Unknown";
        }

        private static double Median(List<double> values)
        {
            if (values.Count == 0) return Double.NaN;
            values.Sort();
            int middle = values.Count / 2;
            return values.Count % 2 == 1 ? values[middle] : (values[middle - 1] + values[middle]) / 2;
        }

        private List<double> BaselineFor(string route)
        {
            List<double> values = new List<double>();
            for (int i = samples.Count - 1; i >= 0 && values.Count < 6; i--)
            {
                Sample item = samples[i];
                if (item.Baseline && item.Route == route && !Double.IsNaN(item.Latency)) values.Add(item.Latency);
            }
            return values;
        }

        public ConnectionQualityView Observe(string targetKey, bool completed, string stampUtc,
            string status, string route, string latency, DateTime nowUtc)
        {
            if (!completed || String.IsNullOrWhiteSpace(targetKey) || targetKey.Length > 256) return null;
            DateTime stamp;
            DateTime now = nowUtc.ToUniversalTime();
            if (!DateTime.TryParseExact(stampUtc, "o", CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind, out stamp) || stamp.Kind != DateTimeKind.Utc ||
                stamp < notBefore || stamp < now.AddMinutes(-30) || stamp > now.AddMinutes(1)) return null;
            if (!String.Equals(target, targetKey, StringComparison.OrdinalIgnoreCase))
            {
                samples.Clear(); lastStamp = DateTime.MinValue; target = targetKey;
            }
            if (stamp <= lastStamp) return null; // Re-rendering and delayed old results are not new checks.
            lastStamp = stamp;
            samples.RemoveAll(delegate(Sample x) { return x.Time < now.AddMinutes(-30); });
            while (samples.Count >= 20) samples.RemoveAt(0);
            Sample previous = samples.Count > 0 ? samples[samples.Count - 1] : null;
            string kind = RouteClass(route);
            string key = kind == "Unknown" ? "" : route.Trim().ToLowerInvariant();
            double ms = ParseLatency(latency);
            Sample current = new Sample { Time = stamp, Route = key, RouteClass = kind,
                Status = status, Latency = ms };
            ConnectionQualityView view = new ConnectionQualityView();
            view.CheckCount = samples.Count + 1;
            view.Explanation = "From completed checks in this app session only, not continuous monitoring. " +
                "Baselines use up to six comparable results from the last 20 checks within 30 minutes. " +
                "Direct, relay locations and peer-relay paths are compared separately. " +
                "This is check-to-check latency, not packet jitter, bandwidth or an RDP test.";

            if (status != "Reachable")
            {
                samples.Add(current);
                view.Summary = status == "Unreachable" ? "Not reachable on this check" : "Connection quality not measured";
                view.Baseline = "No current measurement";
                if (status == "Unreachable" && previous != null && previous.Status == "Reachable")
                {
                    view.EventText = "Peer became unreachable on a completed check";
                    view.Tone = "warn";
                }
                return view;
            }
            if (kind == "Unknown" || Double.IsNaN(ms))
            {
                samples.Add(current);
                view.Summary = kind == "Unknown" ? "Reachable; path not measured" : "Reachable; latency not measured";
                view.Baseline = "Insufficient measurement";
                return view;
            }

            List<double> baseline = BaselineFor(key);
            double median = Median(baseline);
            view.Median = median;
            view.ComparableCount = baseline.Count;
            if (baseline.Count >= 3)
            {
                int direction = ms - median >= 35 && ms >= Math.Max(1, median) * 1.7 ? 1 :
                    (median - ms >= 25 && ms <= median * 0.7 ? -1 : 0);
                current.Direction = direction;
                current.Streak = direction != 0 && previous != null && previous.Route == key &&
                    previous.Status == "Reachable" && previous.Direction == direction ? previous.Streak + 1 :
                    (direction == 0 ? 0 : 1);
                current.Baseline = direction == 0;
                view.Summary = "Latency within recent range";
                if (direction == 1)
                {
                    view.Summary = current.Streak < 2 ? "Higher latency on this check" : "Latency remains above baseline";
                    view.Tone = current.Streak < 2 ? "muted" : "warn";
                    if (current.Streak == 2) SetLatencyEvent(view, "latency_up", median, ms);
                }
                else if (direction == -1)
                {
                    view.Summary = current.Streak < 2 ? "Lower latency on this check" : "Latency improved across two checks";
                    if (current.Streak >= 2)
                    {
                        view.Tone = "good";
                        if (current.Streak == 2) SetLatencyEvent(view, "latency_down", median, ms);
                        // A confirmed improvement becomes the new baseline, not an eternal anomaly.
                        foreach (Sample item in samples) if (item.Route == key) item.Baseline = false;
                        previous.Baseline = true; current.Baseline = true;
                    }
                }
                else if (previous != null && previous.Route == key && previous.Direction == 1 && previous.Streak >= 2)
                {
                    view.Summary = "Latency returned to recent range"; view.Tone = "good";
                    SetLatencyEvent(view, "latency_down", previous.Latency, ms);
                }
            }
            else
            {
                current.Baseline = true;
                view.Summary = "Building a recent latency baseline";
            }

            samples.Add(current);
            List<double> updated = BaselineFor(key);
            if (baseline.Count < 3) { view.Median = Median(updated); view.ComparableCount = updated.Count; }
            view.Baseline = view.ComparableCount >= 3 ?
                "Typical " + Math.Round(view.Median).ToString(CultureInfo.InvariantCulture) + " ms / " + view.ComparableCount + " checks" :
                view.ComparableCount + " of 3 comparable checks";
            if (baseline.Count < 3 && view.ComparableCount >= 3) view.Summary = "Recent latency baseline ready";

            if (previous != null && previous.Status == "Unreachable")
            {
                view.Summary = "Peer is reachable again"; view.Tone = "good";
                view.EventText = "Peer became reachable on a completed check";
                view.EventCode = "";
            }
            else if (previous != null && previous.Status == "Reachable" &&
                previous.RouteClass != "Unknown" && previous.Route != key)
            {
                view.Summary = kind == "Direct" ? "Direct path restored" :
                    (previous.RouteClass == kind ? "Relay path changed; baseline kept separate" : "Path changed; baseline kept separate");
                view.Tone = kind == "Direct" ? "good" : "muted";
                view.EventText = previous.RouteClass == kind ? "Relay path changed between checks" :
                    "Connection path changed: " + previous.RouteClass + " to " + kind;
                view.EventCode = kind == "Direct" ? "route_direct" : (kind == "Relay" ? "route_relay" : "");
                view.Before = view.After = -1;
            }
            int fallbacks = 0;
            int start = Math.Max(0, samples.Count - 8);
            for (int i = start + 1; i < samples.Count; i++)
            {
                Sample a = samples[i - 1], b = samples[i];
                if (a.Status != "Reachable" || b.Status != "Reachable" || a.RouteClass == "Unknown" || b.RouteClass == "Unknown") continue;
                if (a.Route != b.Route) view.RouteChanges++;
                if (a.RouteClass == "Direct" && b.RouteClass == "Relay") fallbacks++;
            }
            // These describe observations, never uninterrupted connection uptime.
            if (fallbacks >= 2 && kind == "Relay")
            {
                view.Summary = "Repeated relay fallback in recent checks"; view.Tone = "warn";
            }
            else if (view.RouteChanges >= 3)
            {
                view.Summary = "Route switched " + view.RouteChanges + " times in recent checks"; view.Tone = "warn";
            }
            return view;
        }

        private static void SetLatencyEvent(ConnectionQualityView view, string code, double before, double after)
        {
            view.EventCode = code;
            view.Before = (int)Math.Round(before); view.After = (int)Math.Round(after);
            view.EventText = (code == "latency_up" ? "Latency stayed above baseline: " : "Latency improved: ") +
                view.Before + " to " + view.After + " ms";
        }
    }
}
