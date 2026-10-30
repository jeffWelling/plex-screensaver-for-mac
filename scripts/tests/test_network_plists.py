"""Check the shipping hosts permit explicit LAN HTTP without disabling Internet ATS."""
import ipaddress
import plistlib
import unittest
from pathlib import Path


class NetworkPlistTests(unittest.TestCase):
    def test_hosts_allow_only_local_http_exceptions(self):
        root = Path(__file__).resolve().parents[2]
        for name in ("PlexSaver", "MontageOptions", "SaverTest"):
            with self.subTest(bundle=name):
                with (root / name / "Info.plist").open("rb") as stream:
                    info = plistlib.load(stream)
                self.assertTrue(info["NSLocalNetworkUsageDescription"])
                ats = info["NSAppTransportSecurity"]
                self.assertTrue(ats["NSAllowsLocalNetworking"])
                self.assertFalse(ats.get("NSAllowsArbitraryLoads", False))
                exceptions = ats["NSExceptionDomains"]
                self.assertEqual(set(exceptions), {
                    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                    "169.254.0.0/16", "fc00::/7", "fe80::/10",
                })
                for network, policy in exceptions.items():
                    self.assertTrue(ipaddress.ip_network(network).is_private)
                    self.assertEqual(policy, {"NSExceptionAllowsInsecureHTTPLoads": True})
