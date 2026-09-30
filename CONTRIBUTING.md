# Contributing

Changes should be focused, easy to review and covered by regression tests where practical. Bug reports should include the app version, expected behaviour and steps to reproduce the problem, without personal or device-specific information.

## Testing changes

Run the source checks before submitting a change. Application, installer and updater changes also need the applicable Windows tests. Passing a source check does not establish that a packaged application works.

Repairs must remain limited to Tailscale. Remote-device failures and optional diagnostics must not authorize automatic repair. Preserve intentional disconnects, local settings, update integrity checks and recovery records.

Use synthetic or disposable test fixtures. Do not include screenshots, raw logs, local configuration, addresses or credentials in commits or issues. See [Privacy](docs/PRIVACY.md).

## Repository checks

Build tooling checks the repository identity against `repository-policy.json`. The source preflight verifies this binding, repository contents and reachable history. Release publishing is disabled until the required testing and review are complete.
