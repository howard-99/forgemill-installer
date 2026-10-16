"""Keep the operator-tested fresh ESXi install at the top of README.

The original fresh Ubuntu ForgeMill installation must remain intact and
prominent as the second main section.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "README.md"
UBUNTU_INSTALL_COMMAND = (
    "sudo apt-get update && sudo apt-get install -y --no-install-recommends "
    "ca-certificates curl && curl -fsSL --retry 3 "
    "https://raw.githubusercontent.com/howard-99/forgemill-installer/main/install-forgemill.bash "
    "-o install-forgemill.bash && sudo bash install-forgemill.bash"
)
ESXI_COMMANDS = (
    "esxcli network firewall ruleset set -e true -r httpClient",
    "wget --no-check-certificate -O /tmp/forgemill-esxi-import.sh "
    "https://raw.githubusercontent.com/howard-99/forgemill-installer/main/esxi-templates/import.sh",
    "sh /tmp/forgemill-esxi-import.sh all",
)


class ReadmeFirstInstallTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.content = README.read_text(encoding="utf-8")

    def test_esxi_installer_is_first_section_with_exact_tested_commands(self):
        headings = [line for line in self.content.splitlines()
                    if line.startswith("## ")]
        self.assertGreaterEqual(len(headings), 5)
        self.assertEqual(
            headings[0],
            "## Fresh ESXi — install all three templates (tested SSH commands)"
        )
        self.assertEqual(headings[1], "## One-command installation")
        section = self.content.split("## One-command installation", 1)[0]
        last = -1
        for cmd in ESXI_COMMANDS:
            index = section.find(cmd)
            self.assertGreater(index, last, cmd)
            last = index
        self.assertIn("Template-MikroTik-CHR-7.21rc6", section)
        self.assertIn("Template-Ubuntu-24.04", section)
        self.assertIn("Template-Rocky-9.8", section)

    def test_existing_ubuntu_installation_remains_available(self):
        self.assertIn("Ubuntu 22.04, 24.04 or 26.04 LTS", self.content)
        self.assertIn(UBUNTU_INSTALL_COMMAND, self.content)
        self.assertLess(
            self.content.index("## One-command installation"),
            self.content.index("## What it installs")
        )

    def test_download_source_and_certificate_risk_are_explicit(self):
        first = self.content.split("## One-command installation", 1)[0]
        self.assertIn("--no-check-certificate", first)
        self.assertIn("TLS certificate verification", first)
        self.assertIn("172.31.31.183/iso", first)
        self.assertIn("BASE_URL", first)
        self.assertIn("SHA-256", first)


if __name__ == "__main__":
    unittest.main()
