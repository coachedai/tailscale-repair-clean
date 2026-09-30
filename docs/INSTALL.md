# Installation

The 3.0 line is still in release-candidate testing. A stable public installer is not published until the package, privacy, upgrade and physical-environment release gates have passed.

This public source repository does not by itself publish or authorize an installer. Workflow artifacts and source archives are development/verification material, not the stable download channel.

## Stable installation flow

When a stable release is published, use the installer attached to the GitHub Release for that version. Native Windows Setup configures the Quick Repair application and protected components, asks for the Tailscale device to check, and offers the optional start-with-Windows setting.

Installing or replacing protected repair components uses normal Windows administrator approval from the same account that launched Setup.

Ordinary application updates remain user-level. Updates that replace protected components use the verified Setup handoff before changing protected files.

## Existing installations

Do not uninstall a working copy, delete its configuration, replace files from the source tree, or edit version metadata to move between builds.

Upgrade acceptance is performed against exact hash-pinned predecessor and candidate packages with configuration preservation. The installed updater follows the signed/hashed update metadata it already trusts; changing repository visibility does not silently redirect it to a different build.

