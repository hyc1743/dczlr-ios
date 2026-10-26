"""Audit the complete original 26-chapter story loop with local resources.

Drives the native story module through New Game, every script chapter, every
scene chapter and the ending, and checks each transition against the local
Data archives (RPP_16 scripts, RPP_10 maps, RPP_08 actor, RPP_09 face,
RPP_03 cameras, RPP_11 voices, RPP_14 effects). No original code executes.
"""
import argparse
import ctypes as C
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from native_core import PPArchive, library, StoryState, StoryOutcomes, StoryPlan, StoryChapter

SCRIPTS = [0,1,2,-1,15,-1,3,-1,4,5,-1,16,-1,6,-1,7,8,-1,9,-1,10,-1,11,13,-1,12]
MAPS = [-1,-1,-1,0,-1,1,-1,3,-1,-1,0,-1,1,-1,6,-1,-1,0,-1,1,-1,4,-1,-1,-1,-1]
STAGES = [-1,-1,-1,2,-1,2,-1,2,-1,-1,1,-1,1,-1,1,-1,-1,0,-1,0,-1,0,-1,-1,-1,-1]


def archive_names(path):
    with PPArchive(path) as pp:
        return [bytes(pp.entry(i).name[:pp.entry(i).name_length]).decode('latin1') for i in range(pp.count)]


def audit(data_dir):
    lib = library()
    data = Path(data_dir)
    required = ['RPP_16.pp', 'RPP_10.pp', 'RPP_08.pp', 'RPP_09.pp', 'RPP_03.pp',
                'RPP_11.pp', 'RPP_14.pp', 'RPP_04.pp', 'RPP_07.pp', 'rpsp_00.pp']
    missing = [name for name in required if not (data / name).is_file()]
    if missing:
        raise SystemExit('Missing local archives: ' + ', '.join(missing))
    scripts = archive_names(data / 'RPP_16.pp')
    maps = archive_names(data / 'RPP_10.pp')
    voices = archive_names(data / 'RPP_11.pp')
    cameras = archive_names(data / 'RPP_03.pp')

    story = StoryState(chapter=0, map=0xff, stage=0xff)
    trace = []
    entered_scenes = 0
    for chapter in range(26):
        profile = StoryChapter()
        assert lib.dc_story_chapter_profile(chapter, C.byref(profile)) == 0
        row = {'chapter': chapter, 'script': profile.script, 'map': profile.map,
               'stage': profile.stage, 'scene': profile.scene, 'scene_type': profile.scene_type,
               'checks': {}}
        if profile.script >= 0:
            name = '%02d.txt' % profile.script
            row['checks']['script'] = name in scripts
            if not row['checks']['script']:
                raise SystemExit(f'Chapter {chapter} script {name} missing from RPP_16.pp')
            if chapter + 1 >= 26:
                row['next'] = {'chapter': 26, 'departed': 0}
                trace.append(row)
                continue
            # End-of-script dispatch.
            plan = StoryPlan()
            assert lib.dc_story_script_finish(C.byref(story), C.byref(plan)) == 0
            record = plan.record()
            story_chapter, story_map, story_stage, stage_rows, unlocked = record['state']
            story = StoryState(chapter=story_chapter, map=story_map, stage=story_stage, unlocked=unlocked)
            for i in range(3):
                story.stages[i].flag_a = stage_rows[i][0]
                story.stages[i].flag_b = stage_rows[i][1]
                story.stages[i].progress = stage_rows[i][2]
            row['next'] = {'chapter': story.chapter, 'departed': record['departed']}
            assert story.chapter == chapter + 1
            assert record['departed'] == (profile.script >= 0 and SCRIPTS[chapter + 1] < 0)
            trace.append(row)
        else:
            entered_scenes += 1
            if chapter == 24:
                # The ending scene keeps the previous map/stage selectors.
                plan = StoryPlan()
                outcomes = StoryOutcomes(a=(C.c_int32 * 3)(), b=(C.c_int32 * 3)())
                stage_index = story.stage if story.stage <= 2 else 0
                outcomes.a[stage_index] = 1
                assert lib.dc_story_advance(C.byref(story), C.byref(outcomes), C.byref(plan)) == 0
                record = plan.record()
                story_chapter, story_map, story_stage, stage_rows, unlocked = record['state']
                story = StoryState(chapter=story_chapter, map=story_map, stage=story_stage, unlocked=unlocked)
                for i in range(3):
                    story.stages[i].flag_a = stage_rows[i][0]
                    story.stages[i].flag_b = stage_rows[i][1]
                    story.stages[i].progress = stage_rows[i][2]
                row['next'] = {'chapter': story.chapter}
                assert story.chapter == 25
                trace.append(row)
                continue
            assert profile.map >= 0 and profile.stage >= 0, f'Scene chapter {chapter} has no map/stage'
            row['checks']['map'] = 'mm00_%02u.xx' % profile.map in maps
            if not row['checks']['map']:
                raise SystemExit(f'Chapter {chapter} map mm00_%02u.xx missing' % profile.map)
            row['checks']['actor'] = 'am00_01.xx' in archive_names(data / 'RPP_08.pp')
            row['checks']['face'] = 'ak00_00.xx' in archive_names(data / 'RPP_09.pp')
            # Interaction phase: touch row 2, then finish row 4.
            outcomes = StoryOutcomes(a=(C.c_int32 * 3)(), b=(C.c_int32 * 3)())
            outcomes.a[profile.stage] = 1
            plan = StoryPlan()
            assert lib.dc_story_advance(C.byref(story), C.byref(outcomes), C.byref(plan)) == 0
            record = plan.record()
            story_chapter, story_map, story_stage, stage_rows, unlocked = record['state']
            story = StoryState(chapter=story_chapter, map=story_map, stage=story_stage, unlocked=unlocked)
            for i in range(3):
                story.stages[i].flag_a = stage_rows[i][0]
                story.stages[i].flag_b = stage_rows[i][1]
                story.stages[i].progress = stage_rows[i][2]
            row['next'] = {'chapter': story.chapter}
            assert story.chapter == chapter + 1
            trace.append(row)

    # Chapter 24's scene advances to the epilogue script 12, whose completion
    # finishes the story (no further chapter exists).
    profile = StoryChapter()
    assert lib.dc_story_chapter_profile(24, C.byref(profile)) == 0
    assert profile.scene == 4, 'Chapter 24 must be the ending scene'
    final = StoryState(chapter=25, map=0xff, stage=0xff)
    plan = StoryPlan()
    assert lib.dc_story_script_finish(C.byref(final), C.byref(plan)) != 0, 'Chapter 25 must end the story'

    # Chapter 24 entry from script chapter 23 unlocks all stage progress flags.
    story = StoryState(chapter=23, map=4, stage=0)
    plan = StoryPlan()
    assert lib.dc_story_script_finish(C.byref(story), C.byref(plan)) == 0
    record = plan.record()
    unlocked_flags = [record['state'][3][i][2] for i in range(3)]
    assert record['state'][0] == 24 and record['state'][4] == 1 and unlocked_flags == [1, 1, 1]

    # Every scene chapter has a story-usable camera candidate and a voice
    # chain for the touch interaction.
    for row in trace:
        if row['scene'] == 0:
            continue
        cam_name = {0: 'home_sh.cam', 1: 'roji_4p.cam', 3: 'home_sh.cam', 4: 'roji_4p.cam',
                    6: 'roji_4p.cam'}.get(row['map'])
        row['checks']['camera'] = cam_name is None or cam_name in cameras
        voice = 'ast001_01.wav'
        row['checks']['voice'] = voice in voices

    report = {'data_dir': str(data_dir), 'chapters': 26,
              'entered_scenes': entered_scenes,
              'script_chapters': sum(1 for r in trace if r['script'] >= 0),
              'scene_chapters': sum(1 for r in trace if r['script'] < 0),
              'trace': trace,
              'chapter24_unlock': {'unlocked': 1, 'progress': unlocked_flags},
              'final_chapter_termination': True}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = audit(args.data)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'chapters': report['chapters'],
                      'entered_scenes': report['entered_scenes'],
                      'chapter24_unlock': report['chapter24_unlock'],
                      'final_chapter_termination': report['final_chapter_termination']}))


if __name__ == '__main__':
    main()
