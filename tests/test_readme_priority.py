"""Keep fresh Ubuntu ForgeMill installation first in the repository README."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "README.md"
INSTALL_COMMAND = (
    "sudo apt-get update && sudo apt-get install -y --no-install-recommends "
    "ca-certificates curl && curl -fsSL --retry 3 "
    "https://raw.githubusercontent.com/howard-99/forgemill-installer/main/install-forgemill.bash "
    "-o install-forgemill.bash && sudo bash install-forgemill.bash"
)

class ReadmeFirstInstallTest(unittest.TestCase):
    def test_fresh_ubuntu_installation_is_first_readme_section(self):
        content = README.read_text(encoding="utf-8")
        headings = [line for line in content.splitlines() if line.startswith("## ")]
        self.assertGreaterEqual(len(headings), 4)
        self.assertEqual(headings[0], "## One-command installation")
        self.assertLess(content.index("## One-command installation"),
                        content.index("## Fresh ESXi host"))
        self.assertIn("Ubuntu 22.04, 24.04 or 26.04 LTS", content)
        self.assertIn(INSTALL_COMMAND, content)
        self.assertLess(content.index("## What it installs"),
                        content.index("## Fresh ESXi host"))

if __name__ == "__main__":
    unittest.main()
