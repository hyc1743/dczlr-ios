from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from check_ios_sprite import presented_scenes, scene_evidence, scene_ready,new_game_evidence


class SceneEvidenceTests(unittest.TestCase):
    def test_intro_requires_complete_order_and_its_own_audio_marker(self):
        lines=['2026-10-24T12:00:00Z PORTLAB_SCENE_PRESENTED='+scene+' submitted' for scene in ('startup','warning','title','intro')]
        audio='2026-10-24T12:00:40Z PORTLAB_INTRO_AUDIO_ADVANCED submitted'
        for invalid in (lines,lines[:-1]+[audio],lines+[audio.replace(' PORTLAB',' echo PORTLAB')],lines+[audio.replace('ADVANCED','ADVANCED_pending')]):
            with self.assertRaises(ValueError):new_game_evidence('\n'.join(invalid))
        self.assertEqual(new_game_evidence('\n'.join(lines+[audio]))['complete_game'],'not verified')

    def test_pose_requires_changed_transform_marker_and_presented_scene(self):
        log="2026-10-24T12:00:00Z PORTLAB_SCENE_PRESENTED=checker submitted\n"
        self.assertFalse(scene_ready(log,"checker",require_pose=True))
        for marker in ("command echo PORTLAB_NATIVE_POSE_ADVANCED","PORTLAB_NATIVE_POSE_ADVANCED_pending"):
            self.assertFalse(scene_ready(log+"2026-10-24T12:00:01Z "+marker+"\n","checker",require_pose=True))
        with self.assertRaises(ValueError):scene_evidence(log,"checker",require_pose=True)
        log+="2026-10-24T12:00:01Z PORTLAB_NATIVE_POSE_ADVANCED submitted\n"
        self.assertEqual(scene_evidence(log,"checker",require_pose=True)['native_pose_sampling'],
                         'changed self-authored XA node transform and presentation reported')
        self.assertFalse(scene_ready(log,"title",require_pose=True))

    def test_xx_requires_its_own_exact_marker_and_scene(self):
        log = "2026-10-24T12:00:00Z PORTLAB_SCENE_PRESENTED=checker submitted\n"
        self.assertFalse(scene_ready(log, "checker", require_xx=True))
        with self.assertRaises(ValueError):
            scene_evidence(log, "checker", require_xx=True)
        for suffix in ("command echo PORTLAB_NATIVE_XX_FIXTURE_LOADED", "PORTLAB_NATIVE_XX_FIXTURE_LOADED_pending"):
            self.assertFalse(scene_ready(log + "2026-10-24T12:00:01Z " + suffix + "\n", "checker", require_xx=True))
        log += "2026-10-24T12:00:01Z PORTLAB_NATIVE_XX_FIXTURE_LOADED submitted\n"
        self.assertEqual(scene_evidence(log, "checker", require_xx=True)["native_xx_fixture"],
                         "self-authored XX embedded texture and XA material binding presented")
        self.assertFalse(scene_ready(log, "title", require_xx=True))

    def test_material_sampling_requires_changed_sample_and_presentation_report(self):
        log = ("2026-10-23T12:00:00Z PORTLAB_SCENE_PRESENTED=checker submitted\n"
               "2026-10-23T12:00:01Z PORTLAB_NATIVE_ANIMATION_ADVANCED submitted\n"
               "2026-10-23T12:00:01Z PORTLAB_NATIVE_XA_FIXTURE_LOADED submitted\n")
        self.assertFalse(scene_ready(log, "checker", True, True, True))
        with self.assertRaises(ValueError):
            scene_evidence(log, "checker", True, True, True)
        echoed = log + "2026-10-23T12:00:02Z command echo PORTLAB_NATIVE_MATERIAL_ADVANCED\n"
        self.assertFalse(scene_ready(echoed, "checker", True, True, True))
        observed = log + "2026-10-23T12:00:02Z PORTLAB_NATIVE_MATERIAL_ADVANCED submitted\n"
        self.assertEqual(scene_evidence(observed, "checker", True, True, True)["native_material_sampling"],
                         "changed alpha sample and presentation reported")

    def test_xa_pipeline_requires_its_own_report_after_scene_and_motion(self):
        log = ("2026-10-23T12:00:00Z PORTLAB_SCENE_PRESENTED=checker submitted\n"
               "2026-10-23T12:00:01Z PORTLAB_NATIVE_ANIMATION_ADVANCED submitted\n")
        self.assertFalse(scene_ready(log, "checker", require_animation=True, require_xa=True))
        echoed = log + "2026-10-23T12:00:02Z command echo PORTLAB_NATIVE_XA_FIXTURE_LOADED\n"
        self.assertFalse(scene_ready(echoed, "checker", require_animation=True, require_xa=True))
        verified = log + "2026-10-23T12:00:02Z PORTLAB_NATIVE_XA_FIXTURE_LOADED submitted\n"
        report = scene_evidence(verified, "checker", require_animation=True, require_xa=True)
        self.assertEqual(report["native_xa_fixture"], "self-authored XA decode and animation pipeline reported")

    def test_first_frame_does_not_prove_animation_advancement(self):
        log = "2026-10-23T12:00:00Z PORTLAB_SCENE_PRESENTED=checker submitted\n"
        self.assertFalse(scene_ready(log, "checker", require_animation=True))
        with self.assertRaises(ValueError):
            scene_evidence(log, "checker", require_animation=True)
        echoed = log + "2026-10-23T12:00:01Z command echo PORTLAB_NATIVE_ANIMATION_ADVANCED\n"
        self.assertFalse(scene_ready(echoed, "checker", require_animation=True))
        advanced = log + "2026-10-23T12:00:01Z PORTLAB_NATIVE_ANIMATION_ADVANCED submitted\n"
        self.assertTrue(scene_ready(advanced, "checker", require_animation=True))
        self.assertEqual(scene_evidence(advanced, "checker", require_animation=True)["native_animation_tick"],
                         "positive-delta advancement and presentation reported")

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
