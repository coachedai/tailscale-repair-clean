# Privacy

Quick Repair stores device selection and settings locally under `%LOCALAPPDATA%\TailscaleQuickRepair`. The selected target is used for connection checks and is not uploaded to GitHub.

## Support reports

The optional report contains a limited set of product status information. It can be reviewed before copying or saving. Reports are not uploaded automatically.

Screenshots, raw logs, configuration files, addresses, device names, account details and credentials must not be included in public bug reports. A description of the behaviour and the app version is usually sufficient.

## Source and release checks

Source files, reachable Git history, staged packages and final expanded packages are checked separately. Findings block publication. Diagnostic messages use reason codes and hashes rather than printing matched private values.

Automated tests use synthetic or disposable fixtures, not a person's computer records. Pattern checks supplement review; they cannot identify every possible form of personal information.

Distributed packages must contain only application files and integrity metadata. Developer notes and machine-specific evidence are not part of the product.

## Public repository hygiene

Public source is fail-closed against personal information, machine identifiers, network identifiers, secrets, cross-project content, screenshots and raw evidence. Only product source, tests, release tooling and public documentation belong in the repository. Local development artifacts are rejected before publication rather than relying on manual cleanup afterwards.
