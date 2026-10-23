"""Guard against treating launch arguments or incomplete guest output as a pass."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from run_wine_boot_probe import run, SUBSYSTEM_MARKERS, WIN32_MARKER


class FakeHost:
    returncode = None

    def poll(self):
        return self.returncode

    def wait(self, timeout):
        self.returncode = 0

    def terminate(self):
        self.returncode = -15


class WineEvidenceTests(unittest.TestCase):
    def execute(self, guest_output, *, succeeds, use_probe=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            exe = root / "self-authored-probe.exe"
            exe.write_bytes(b"fixture only; never executed")
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.dict(sys.modules, {
                    "pty": types.SimpleNamespace(openpty=lambda: (100, 101))}))
                stack.enter_context(patch("run_wine_boot_probe.sys.platform", "darwin"))
                stack.enter_context(patch("run_wine_boot_probe.os.close"))
                stack.enter_context(patch("run_wine_boot_probe.os.fdopen",
                                          return_value=io.StringIO(guest_output)))
                stack.enter_context(patch("run_wine_boot_probe.subprocess.Popen",
                                          return_value=FakeHost()))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                if succeeds:
                    run(root / "host", root / "root.zip", root / "output", 1,
                        exe if use_probe else None)
                else:
                    with self.assertRaises(SystemExit):
                        run(root / "host", root / "root.zip", root / "output", 1,
                            exe if use_probe else None)
            report = json.loads((root / "output/wine-boot-report.json").read_text())
            self.assertEqual(report["guest_output_marker_observed"], succeeds)
            return report

    def test_echoed_command_does_not_prove_guest_execution(self):
        self.execute('Launching "cmd.exe" "/c" "echo" "PORTLAB_WINE32_OK"\n',
                     succeeds=False, use_probe=False)

    def test_summary_marker_without_subsystem_results_fails(self):
        self.execute(WIN32_MARKER + "\n", succeeds=False)

    def test_terminal_escapes_are_accepted_but_device_claims_remain_unverified(self):
        output = "\n".join(SUBSYSTEM_MARKERS) + "\n\x1b[?25l" + WIN32_MARKER + "\x1b[?25h\n"
        report = self.execute(output, succeeds=True)
        self.assertTrue(all(report["subsystem_markers"].values()))
        self.assertEqual(report["ios_execution"], "not_tested")
        self.assertEqual(report["d3d9"], "not_tested")
        self.assertIn("dummy SDL", report["audio"])

    def test_console_pass_does_not_claim_graphics_or_audio(self):
        report = self.execute("PORTLAB_WINE32_OK\n", succeeds=True, use_probe=False)
        self.assertEqual(report["graphics"], "not_tested")
        self.assertEqual(report["audio"], "not_tested")


if __name__ == "__main__":
    unittest.main()
