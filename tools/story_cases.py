"""Story dispatcher tables and chapter-end semantics."""
import ctypes as C
from itertools import product
from native_core import StoryState, StoryOutcomes, StoryPlan, StoryChapter, library

SCRIPTS = [0,1,2,-1,15,-1,3,-1,4,5,-1,16,-1,6,-1,7,8,-1,9,-1,10,-1,11,13,-1,12]
FRAMES = [2,31,9,-1,2,-1,38,-1,31,5,-1,2,-1,42,-1,43,4,-1,4,-1,51,-1,74,4,-1,13]
MAPS = [-1,-1,-1,0,-1,1,-1,3,-1,-1,0,-1,1,-1,6,-1,-1,0,-1,1,-1,4,-1,-1,-1,-1]
STAGES = [-1,-1,-1,2,-1,2,-1,2,-1,-1,1,-1,1,-1,1,-1,-1,0,-1,0,-1,0,-1,-1,-1,-1]
SCENES = [0,0,0,1,0,2,0,3,0,0,1,0,2,0,3,0,0,1,0,2,0,3,0,0,4,0]
TYPES = [3,3,3,4,3,5,3,6,3,3,4,3,5,3,6,3,3,4,3,5,3,6,3,3,2,3]


def story_cases():
    """Exhaustive profile lookups plus chapter-end transitions."""
    for chapter in range(26):
        yield ('profile', chapter)
    for chapter in range(26):
        profile = StoryChapter()
        assert library().dc_story_chapter_profile(chapter, C.byref(profile)) == 0
        if profile.script < 0:
            continue
        if chapter + 1 >= 26:
            yield ('finish_last', chapter)
        elif SCRIPTS[chapter + 1] < 0:
            yield ('finish_depart', chapter)
        else:
            yield ('finish_script', chapter)
    for chapter in (3, 10, 17):
        for stage in range(3):
            for fa, fb in product((0, 1), repeat=2):
                yield ('advance', chapter, stage, fa, fb, 2)
            for action in (2, 3, 4, 5):
                yield ('menu_action', chapter, stage, action)


def run_story_cases():
    lib = library()
    for case in story_cases():
        kind = case[0]
        if kind == 'profile':
            chapter = case[1]
            profile = StoryChapter()
            status = lib.dc_story_chapter_profile(chapter, C.byref(profile))
            assert status == 0, f'profile status {status} for chapter {chapter}'
            assert profile.script == SCRIPTS[chapter], f'chapter {chapter} script {profile.script}'
            assert profile.last_frame == FRAMES[chapter], f'chapter {chapter} frame'
            assert profile.map == MAPS[chapter], f'chapter {chapter} map'
            assert profile.stage == STAGES[chapter], f'chapter {chapter} stage'
            assert profile.scene == SCENES[chapter], f'chapter {chapter} scene'
            assert profile.scene_type == TYPES[chapter], f'chapter {chapter} type'
        elif kind == 'finish_last':
            chapter = case[1]
            state = StoryState(chapter=chapter, map=2, stage=0)
            plan = StoryPlan()
            status = lib.dc_story_script_finish(C.byref(state), C.byref(plan))
            assert status != 0, f'chapter {chapter} finish must stay in range'
        elif kind == 'finish_depart':
            chapter = case[1]
            state = StoryState(chapter=chapter, map=2, stage=0)
            plan = StoryPlan()
            status = lib.dc_story_script_finish(C.byref(state), C.byref(plan))
            assert status == 0, f'script finish status {status} chapter {chapter}'
            record = plan.record()
            assert record['state'][0] == chapter + 1
            assert record['departed'] == 1
            assert any(c[0] == 3 for c in record['commands'])  # ENTER_SCENE
            assert any(c[0] == 2 for c in record['commands'])  # SET_MAP_STAGE
            assert record['state'][1] == (MAPS[chapter + 1] if MAPS[chapter + 1] >= 0 else 2)
            assert record['state'][2] == (STAGES[chapter + 1] if STAGES[chapter + 1] >= 0 else 0)
        elif kind == 'finish_script':
            chapter = case[1]
            state = StoryState(chapter=chapter, map=2, stage=0)
            plan = StoryPlan()
            status = lib.dc_story_script_finish(C.byref(state), C.byref(plan))
            assert status == 0, f'script finish status {status} chapter {chapter}'
            record = plan.record()
            assert record['state'][0] == chapter + 1
            # Script chapters 2/4/6/9/11/13/16/18/20/23 precede scene chapters.
            assert record['departed'] == (SCRIPTS[chapter + 1] < 0)
        elif kind == 'advance':
            chapter, stage, fa, fb, action = case[1:]
            state = StoryState(chapter=chapter, map=MAPS[chapter], stage=stage)
            state.stages[stage].flag_a = fa
            state.stages[stage].flag_b = fb
            outcomes = StoryOutcomes(a=(C.c_int32 * 3)(1, 0, 0), b=(C.c_int32 * 3)(0, 1, 0))
            plan = StoryPlan()
            status = lib.dc_story_advance(C.byref(state), C.byref(outcomes), C.byref(plan))
            assert status == 0, f'advance status {status}'
            record = plan.record()
            assert record['state'][0] == chapter + 1
            # The original writes the table bytes verbatim, including 0xff
            # selectors during script chapters.
            assert record['state'][1] == (MAPS[chapter + 1] if MAPS[chapter + 1] >= 0 else 255)
            assert record['state'][2] == (STAGES[chapter + 1] if STAGES[chapter + 1] >= 0 else 255)
            # Outcome A wins and sets flag_a; outcome B alone sets flag_b.
            # The original keeps prior flags otherwise.
            if outcomes.a[stage] != 0:
                assert record['state'][3][stage][0] == 1
                assert record['state'][3][stage][1] == fb
            elif outcomes.b[stage] != 0:
                assert record['state'][3][stage][0] == fa
                assert record['state'][3][stage][1] == 1
            else:
                assert record['state'][3][stage][0] == fa
                assert record['state'][3][stage][1] == fb
        elif kind == 'menu_action':
            chapter, stage, action = case[1:]
            state = StoryState(chapter=chapter, map=MAPS[chapter], stage=stage)
            plan = StoryPlan()
            status = lib.dc_story_menu_action(C.byref(state), action, C.byref(plan))
            assert status == 0, f'menu action status {status}'
            record = plan.record()
            if action == 2:
                assert record['departed'] == 0
            else:
                assert record['departed'] == 1
            if action == 3:
                assert any(c[0] == 4 for c in record['commands'])
            elif action == 4:
                assert any(c[0] == 5 for c in record['commands'])
            elif action == 5:
                assert any(c[0] == 6 for c in record['commands'])
            else:
                assert record['state'][0] == chapter + 1
    return len(list(story_cases()))


def main():
    lib = library()
    # Chapter 24 entry from script chapter 23 unlocks all stage progress flags.
    state = StoryState(chapter=23, map=4, stage=0)
    plan = StoryPlan()
    assert lib.dc_story_script_finish(C.byref(state), C.byref(plan)) == 0
    record = plan.record()
    assert record['state'][0] == 24
    assert record['state'][4] == 1
    for i in range(3):
        assert record['state'][3][i][2] == 1, f'stage {i} progress'
    # Invalid lookups and states fail without side effects.
    profile = StoryChapter()
    assert lib.dc_story_chapter_profile(26, C.byref(profile)) != 0
    bad = StoryState(chapter=26, map=0, stage=0)
    assert lib.dc_story_script_finish(C.byref(bad), C.byref(plan)) != 0
    assert lib.dc_story_menu_action(C.byref(state), 9, C.byref(plan)) != 0
    print({'story_cases': run_story_cases(), 'chapter24_unlock': True})


if __name__ == '__main__':
    main()
