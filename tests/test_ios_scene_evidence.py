from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from check_ios_sprite import presented_scenes, scene_evidence


class SceneEvidenceTests(unittest.TestCase):
    def test_checker_cannot_certify_original_startup_or_title(self):
        log = "2026-10-23T12:00:00Z PORTLAB_SCENE_PRESENTED=checker submitted\n"
        self.assertEqual(presented_scenes(log), ["checker"])
        self.assertEqual(scene_evidence(log, "checker")["game_playability"], "not verified")
        for expected in ("startup", "title"):
            with self.assertRaises(ValueError):
                scene_evidence(log, expected)

    def test_loaded_assets_and_echoed_commands_are_not_presentation(self):
        for log in ("2026-10-23T12:00:00Z assets loaded\n",
                    "2026-10-23T12:00:00Z command echo PORTLAB_SCENE_PRESENTED=title\n",
                    "PORTLAB_SCENE_PRESENTED=title\n",
                    "2026-10-23T12:00:00Z PORTLAB_SCENE_PRESENTED=title_pending\n"):
            self.assertEqual(presented_scenes(log), [])
            with self.assertRaises(ValueError):
                scene_evidence(log, "title")

    def test_later_presentations_remain_distinct_and_keep_validation_limits(self):
        log = "\n".join("2026-10-23T12:00:00Z PORTLAB_SCENE_PRESENTED=" + scene + " submitted"
                        for scene in ("checker", "startup", "title"))
        report = scene_evidence(log, "title")
        self.assertEqual(report["observed_scenes"], ["checker", "startup", "title"])
        self.assertEqual(report["required_scene"], "title")
        self.assertEqual(report["physical_iphone"], "not tested")
        self.assertEqual(report["game_playability"], "not verified")
        self.assertEqual(report["resource_content"], "not inspected by this presentation check")


if __name__ == "__main__":
    unittest.main()
