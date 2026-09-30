# Tailscale Quick Repair

Tailscale Quick Repair is a small Windows tray app for diagnosing and recovering **local** Tailscale connection problems without resetting the rest of Windows networking.

It checks local Tailscale health, can test a selected remote Tailscale device, keeps useful connection history, and provides bounded recovery when the local client, service or backend gets stuck.

## What it does

- Shows local Tailscale app, service and backend health.
- Checks a selected remote Tailscale device without treating an offline peer as a local-PC fault.
- Shows route and latency information for completed connection checks.
- Provides a read-only local refresh that never probes the selected peer.
- Detects active non-Tailscale VPN/tunnel context using fixed privacy-safe labels.
- Gives Tailscale extra settling time after VPN/network transitions before Automatic Repair evaluates local health.
- Keeps typed local History for useful events, including privacy-safe VPN transitions.
- Provides optional Automatic Repair with repeated confirmation, cooldowns and retry limits.
- Provides read-only Advanced Diagnostics and a support report that can be reviewed before copying or saving.
- Runs quietly in the Windows system tray and can optionally start with Windows.
- Uses native Setup with normal Windows administrator approval when protected components must change.

## Safety boundaries

Quick Repair is intentionally narrow.

It does **not** reset general Windows networking, modify another VPN, change DNS, change routes, repair because a remote peer is merely offline, or override deliberate Tailscale disconnect/sign-in/approval states.

Automatic Repair is optional. A repair is requested only after repeated local evidence and is bounded by retry/cooldown policy.

## Privacy

Device selection and settings stay on the PC. Quick Repair does not upload local configuration to GitHub.

Support reports use an allow-listed projection rather than raw logs. Public bug reports should not include screenshots, raw logs, IP addresses, device names, account details, configuration files or credentials.

See [Privacy](docs/PRIVACY.md).

## Release status

The 3.0 line is still in release-candidate testing. This is the public source repository. The source repository and the installer/update channel are separate release boundaries: source visibility does **not** publish a stable installer or enable updates.

Until a stable GitHub Release is published, do not treat workflow artifacts, source ZIPs or development builds as normal end-user downloads.

See [Installation](docs/INSTALL.md) and [Privacy](docs/PRIVACY.md).

## Contributing

Changes should preserve the product's narrow Tailscale-only scope, privacy boundaries and evidence-based repair rules. See [Contributing](CONTRIBUTING.md).

Tailscale Quick Repair is an independent project and is not an official Tailscale product.
