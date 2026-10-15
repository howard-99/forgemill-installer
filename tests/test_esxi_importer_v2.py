"""Static regression tests for the ESXi BusyBox source-VM importer.

Run: python3 -m unittest discover -s tests -p test_esxi_importer_v2.py -v
Cannot replace deployment/boot validation on an actual ESXi host.
"""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "esxi-templates" / "import.sh"
REPAIR = ROOT / "esxi-templates" / "fix-chr-console-keyboard.sh"


class ESXiImporterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = SCRIPT.read_text(encoding="utf-8")

    def test_posix_shell_syntax(self):
        subprocess.run(["sh", "-n", str(SCRIPT)], check=True)
        subprocess.run(["sh", "-n", str(REPAIR)], check=True)

    def test_default_all_imports_exactly_three(self):
        block = re.search(
            r"(?m)^  all\)\n(?P<body>(?:    import_image [^\n]+\n)+)    ;;",
            self.text,
        )
        self.assertIsNotNone(block)
        self.assertEqual(
            re.findall(r"import_image (\w+)", block["body"]),
            ["ubuntu", "rockyvmware", "chr7237"],
        )

    def test_template_names_and_legacy_guards(self):
        names = (
            "Template-Ubuntu-24.04",
            "Template-Rocky-9.8",
            "Template-MikroTik-CHR-7.23.7",
            "Template-MikroTik-CHR-7.19.6",
        )
        for name in names:
            self.assertEqual(self.text.count("VMNAME='" + name + "'"), 1)
        for needle in (
            "for legacy_name in $LEGACY_NAMES; do",
            "existing_directory",
            "registered_id",
            'already exists but is powered on',
        ):
            self.assertIn(needle, self.text)

    def test_rocky_known_good_ova_and_pvscsi(self):
        self.assertIn("FILE='rocky-9.8-forgemill-vmware.ova'", self.text)
        self.assertIn('"$DISK_SUB" = pvscsi', self.text)
        self.assertIn(
            "2a58c89a81b456e6c90cdae6d2d23152799cd137a42207d50b40d538b4274f33",
            self.text,
        )
        self.assertNotIn("FILE='rocky-9.8.ova'", self.text)

    def test_chr_bios_ide_keyboard_and_optional_7196(self):
        self.assertIn("FILE='chr-7.23.7-legacy-bios.ova'", self.text)
        self.assertIn("FILE='chr-7.19.6-legacy-bios.ova'", self.text)
        self.assertIn("EXPECTED_SHA256=${CHR_7196_SHA256:-}", self.text)
        self.assertIn("EXPECTED_SHA256=${CHR_7237_SHA256:-}", self.text)
        self.assertIn("CTRL_DEFAULT='5|IDE'", self.text)
        self.assertIn('keyboard.allowBothIRQs = "FALSE"', self.text)
        self.assertIn('"$DISK_CTRL" = ide', self.text)
        self.assertRegex(
            self.text, r"(?m)^  chr7196\) import_image chr7196 ;;$"
        )
        default = re.search(
            r"(?m)^  all\)\n(?P<body>(?:    import_image [^\n]+\n)+)    ;;",
            self.text,
        )
        self.assertNotIn("chr7196", default["body"])

    def test_guest_os_uses_raw_vmx_ids_not_api_enums(self):
        # VMX uses 'ubuntu-64'/'otherlinux-64'; vSphere API enums such
        # as 'otherLinux64Guest' cause UnsupportedGuest when booting.
        self.assertIn("GUEST='ubuntu-64'", self.text)
        self.assertEqual(self.text.count("GUEST='otherlinux-64'"), 3)
        self.assertNotIn("GUEST='ubuntu64Guest'", self.text)
        self.assertNotIn("GUEST='otherLinux64Guest'", self.text)
        self.assertIn('case "$GUEST" in', self.text)
        self.assertIn('Invalid raw VMX guestOS identifier', self.text)

    def test_ubuntu_trusted_hash_option(self):
        self.assertIn("FILE='ubuntu-24.04-server-cloudimg-amd64.ova'", self.text)
        self.assertIn("EXPECTED_SHA256=${UBUNTU_SHA256:-}", self.text)

    def test_keyboard_repair_busybox_compatibility(self):
        source = REPAIR.read_text(encoding="utf-8")
        for required in (
            "for candidate in /bin/vim-cmd /sbin/vim-cmd",
            "Refusing to change source VM named",
            "marked as a ForgeMill main-template",
            "Power off the DEPLOYED TEST VM",
            'cp "$VMX" "$BACKUP"',
            '"$VIM_CMD" vmsvc/reload "$VMID"',
        ):
            self.assertIn(required, source)
        self.assertNotIn("command -v vim-cmd", source.split("VIM_CMD=''")[1])

    def test_import_safety_checks(self):
        for needle in (
            "vmkfstools -e", "verify_manifest", "tar -tvf",
            "Unsafe", "staging", "Powered off", "MIN_FREE_GB",
            "Never silently create a renamed duplicate",
        ):
            self.assertIn(needle.lower(), self.text.lower())


if __name__ == "__main__":
    unittest.main()
