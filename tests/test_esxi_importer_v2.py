"""Static regression tests for the standalone ESXi three-template importer.

Run: python3 -m unittest discover -s tests -p test_esxi_importer_v2.py -v
Also checks POSIX sh syntax; ESXi-specific execution requires a real host.
"""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "esxi-templates" / "import.sh"

class ESXiImporterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = SCRIPT.read_text(encoding="utf-8")

    def test_posix_shell_syntax(self):
        subprocess.run(["sh", "-n", str(SCRIPT)], check=True)

    def test_default_all_imports_only_three_verified_images(self):
        m = re.search(
            r"(?m)^  all\)\s*\n(?P<body>(?:    import_image [^\n]+\n)+)    ;;",
            self.text,
        )
        self.assertIsNotNone(m)
        self.assertEqual(re.findall(r"import_image (\w+)", m["body"]),
                         ["ubuntu", "rockyvmware", "chr7237"])

    def test_pretty_source_names_and_legacy_safety(self):
        for name in ("Template-Ubuntu-24.04", "Template-Rocky-9.8",
                     "Template-MikroTik-CHR-7.23.7"):
            self.assertEqual(self.text.count("VMNAME='" + name + "'"), 1)
        self.assertIn("for legacy_name in $LEGACY_NAMES; do", self.text)
        self.assertIn("existing_directory", self.text)
        self.assertIn("registered_id", self.text)
        self.assertIn("SKIP:", self.text)

    def test_rocky_image_is_correct_and_pinned(self):
        self.assertIn("FILE='rocky-9.8-forgemill-vmware.ova'", self.text)
        self.assertIn("DISK_SUB" = pvscsi", self.text)
        self.assertIn(
            "2a58c89a81b456e6c90cdae6d2d23152799cd137a42207d50b40d538b4274f33",
            self.text,
        )
        self.assertNotIn("FILE='rocky-9.8.ova'", self.text)

    def test_chr_legacy_bios_ide_keyboard(self):
        self.assertIn("FILE='chr-7.23.7-legacy-bios.ova'", self.text)
        self.assertIn("CTRL_DEFAULT='5|IDE'", self.text)
        self.assertIn('keyboard.allowBothIRQs = "FALSE"', self.text)
        self.assertIn('DISK_CTRL" = ide', self.text)
        self.assertNotIn("FILE='chr-7.19.6-legacy-bios.ova'", self.text)

    def test_ubuntu_source_and_optional_digest(self):
        self.assertIn("FILE='ubuntu-24.04-server-cloudimg-amd64.ova'", self.text)
        self.assertIn("EXPECTED_SHA256=${UBUNTU_SHA256:-}", self.text)

    def test_critical_data_protections(self):
        for text in [
            "vmkfstools -e", "verify_manifest", "tar -tvf",
            "Unsafe", "staging", "Powered off",
            "MIN_FREE_GB", "Never silently create a renamed duplicate",
        ]:
            self.assertIn(text.lower(), self.text.lower())

if __name__ == "__main__":
    unittest.main()
