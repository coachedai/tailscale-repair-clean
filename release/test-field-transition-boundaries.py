#!/usr/bin/env python3
"""Static safety boundaries for the RC12 physical transition verifier."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'release' / 'field-transition-verify.ps1').read_text('utf-8-sig')


class FieldTransitionBoundaries(unittest.TestCase):
    def test_modes_are_explicit_and_non_destructive(self):
        for mode in ("'Vpn'","'SleepResume'","'RebootBefore'","'RebootAfter'"):
            self.assertIn(mode, SCRIPT)
        for forbidden in (
            'Start-Service','Stop-Service','Restart-Service','Set-Service','Stop-Process','taskkill',
            'Set-Net','New-Net','Remove-Net','Disable-Net','Enable-Net','netsh','ipconfig',
            'Set-DnsClient','Set-ItemProperty','Remove-Item','Invoke-AutoRepair','Repair-Backend',
            'tailscale ping','tailscale up','tailscale down'
        ):
            self.assertNotIn(forbidden, SCRIPT)

    def test_vpn_observation_uses_the_product_fixed_label_boundary(self):
        self.assertIn('[Tqr.VpnAwareness]::Inspect()', SCRIPT)
        self.assertNotIn('Get-NetAdapter', SCRIPT)
        self.assertNotIn('Get-NetRoute', SCRIPT)
        self.assertNotIn('Get-DnsClient', SCRIPT)
        self.assertNotIn('NetworkInterface]::GetAllNetworkInterfaces', SCRIPT)

    def test_local_health_is_observed_without_repair_authority(self):
        self.assertIn('New-Object Tqr.WindowsAutoRepairMachine', SCRIPT)
        self.assertIn('[Tqr.AutoRepairPolicyStore]::ReadEnabled($appRoot)', SCRIPT)
        self.assertIn("'Automatic Repair is off for physical transition verification'", SCRIPT)
        self.assertNotIn('.StartService(', SCRIPT)
        self.assertNotIn('.StopService(', SCRIPT)
        self.assertNotIn('.OpenClient(', SCRIPT)

    def test_results_and_reboot_state_exclude_network_identity(self):
        self.assertIn('containsDeviceData=$false', SCRIPT)
        self.assertIn('containsNetworkData=$false', SCRIPT)
        self.assertIn('changesNetworkSettings=$false', SCRIPT)
        self.assertNotIn('LocalIp', SCRIPT)
        self.assertNotIn('Peer', SCRIPT)
        self.assertNotIn('Exception.Message', SCRIPT)
        self.assertIn("configSha256=[string]$baseline.ConfigSha256", SCRIPT)
        self.assertIn("exeSha256=[string]$baseline.ExeSha256", SCRIPT)
        self.assertIn("librarySha256=[string]$baseline.LibrarySha256", SCRIPT)

    def test_evidence_is_preserved(self):
        self.assertIn("'Existing transition result will not be overwritten'", SCRIPT)
        self.assertIn("'Existing pre-reboot state will not be overwritten'", SCRIPT)
        self.assertNotIn('Remove-Item', SCRIPT)

    def test_real_transition_waits_are_bounded(self):
        self.assertIn('[ValidateRange(60,900)]', SCRIPT)
        self.assertIn("[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)", SCRIPT)
        self.assertIn("'A real VPN or tunnel transition was observed without changing it'", SCRIPT)
        self.assertIn("'A real suspend and resume polling gap was observed'", SCRIPT)


if __name__ == '__main__':
    unittest.main(verbosity=2)
