"""Compare native story chapter-end semantics with the original handler.

The pinned original function FUN_00523380 executes with synthetic main-object
and scene-context records. External cleanup, audio-stop and input-query calls
are bounded stubs; original instructions read the real static chapter tables
at 0x006d39d0/0x006d3a44/0x006d3a84. No game process or resource executes.
"""
import argparse
import ctypes as C
import hashlib
import json
from itertools import product
from pathlib import Path
import struct
from unicorn import UC_PROT_READ, UC_PROT_WRITE
from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_EIP, UC_X86_REG_EAX, UC_X86_REG_EBP
from oracle_animation import OriginalAnimation, OBJECT, TARGET_SHA256
from native_core import library, StoryState, StoryOutcomes, StoryPlan, StoryChapter

SCENE = OBJECT + 0x30000
STAGE_STRIDE = 0x2198
STUBS = {0x464ab0: 'query', 0x47d000: 'stage_cleanup', 0x483bc0: 'scene_cleanup', 0x402510: 'stop'}

# Projection of the native story plan onto the original observable fields.
INSTALL_KNOWN = {3: 0x0050de60, 4: 0x0052e070, 5: 0x0051e010}
CHAPTER_TABLE = [
    0x00605510,0x00605510,0x00605510,0x00512cc0,0x00605510,0x00489f20,
    0x00605510,0x00483510,0x00605510,0x00605510,0x00512cc0,0x00605510,
    0x00489f20,0x00605510,0x00483510,0x00605510,0x00605510,0x00512cc0,
    0x00605510,0x00489f20,0x00605510,0x00483510,0x00605510,0x00605510,
    0x0051abb0,0x00605510
]


def projection(state, outcomes, action, gate):
    """Expected observable state produced by the original chapter-end handler."""
    if not gate:
        return {'chapter': state['chapter'], 'map': state['map'], 'stage': state['stage'],
                'flag_a': state['flag_a'], 'flag_b': state['flag_b'],
                'installed': state['installed'], 'cleared': [0, 0, 0, 0],
                'backup': list(state['backup']), 'stops': 0, 'cleanup_stage': 0,
                'cleanup_scene': 0, 'action_byte': state['action_byte']}
    if action == 0:
        return {'chapter': state['chapter'], 'map': state['map'], 'stage': state['stage'],
                'flag_a': state['flag_a'], 'flag_b': state['flag_b'],
                'installed': state['installed'], 'cleared': [0, 0, 0, 0],
                'backup': list(state['backup']), 'stops': 0, 'cleanup_stage': 0,
                'cleanup_scene': 0, 'action_byte': 0}
    if action == 2:
        flag_a, flag_b = state['flag_a'], state['flag_b']
        if outcomes[0] != 0:
            flag_a = 1
        elif outcomes[1] != 0:
            flag_b = 1
        chapter = state['chapter'] + 1
        return {'chapter': chapter, 'map': MAP_TABLE[chapter], 'stage': STAGE_TABLE[chapter],
                'flag_a': flag_a, 'flag_b': flag_b,
                'installed': CHAPTER_TABLE[chapter], 'cleared': [1, 1, 1, 1],
                'backup': list(state['backup']), 'stops': 0, 'cleanup_stage': 1,
                'cleanup_scene': 1, 'action_byte': state['action_byte']}
    # actions 3/4/5: backup the four active slots, install the destination,
    # stop the 34 context players plus the two stage/mix players.
    return {'chapter': state['chapter'], 'map': state['map'], 'stage': state['stage'],
            'flag_a': state['flag_a'], 'flag_b': state['flag_b'],
            'installed': INSTALL_KNOWN[action], 'cleared': [1, 1, 1, 1],
            'backup': list(state['slots']), 'stops': 36, 'cleanup_stage': 0,
            'cleanup_scene': 0, 'action_byte': 0}


class OriginalChapterEnd(OriginalAnimation):
    def __init__(self, exe):
        super().__init__(exe, {0x523380: 1286})
        self.uc.mem_map(OBJECT + 0x11000, 0x1f000, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(SCENE, 0x2000, UC_PROT_READ | UC_PROT_WRITE)

    def write_guard(self, uc, access, address, size, value, context):
        if 0x10000000 <= address and address + size <= 0x10010000:
            return
        if SCENE <= address and address + size <= SCENE + 0x2000:
            return
        offset = address - OBJECT
        if 0x13538 <= offset < 0x13538 + 3 * STAGE_STRIDE and size == 1:
            return
        if size == 4 and offset in (0x21f78, 0x21f7c, 0x21f80, 0x21f84, 0x21f88,
                                    0x21f98, 0x21f9c, 0x21fa0, 0x21fa4,
                                    0x21fb4, 0x21fb8, 0x21fbc, 0x21fc0):
            return
        if size == 1 and offset in (0x278, 0x68b5, 0x13530, 0x13533, 0x13535):
            return
        raise RuntimeError(f'Chapter end wrote outside admitted state: {address:#x}/{size}')

    def code_guard(self, uc, address, size, context):
        if address in self.instructions:
            return
        if address not in STUBS:
            raise RuntimeError(f'Chapter end left admitted instructions: {address:#x}')
        stack = uc.reg_read(UC_X86_REG_ESP)
        target = self.word(stack)
        if target not in self.instructions:
            raise RuntimeError('Synthetic host return leaves admitted instructions')
        kind = STUBS[address]
        if kind == 'query':
            uc.reg_write(UC_X86_REG_EAX, 1)
        elif kind == 'stage_cleanup':
            args = [self.word(stack + 4 * i) for i in (1, 2, 3)]
            if args[0] != OBJECT or args[1] != SCENE:
                raise RuntimeError('Unexpected stage cleanup arguments')
            self.cleanup_stage += 1
        elif kind == 'scene_cleanup':
            if self.word(stack + 4) != OBJECT:
                raise RuntimeError('Unexpected scene cleanup context')
            self.cleanup_scene += 1
        elif kind == 'stop':
            player = self.word(stack + 4)
            self.stops.append(player)
        uc.reg_write(UC_X86_REG_ESP, stack + 4)
        uc.reg_write(UC_X86_REG_EIP, target)

    def run(self, case):
        self.stops = []
        self.cleanup_stage = self.cleanup_scene = 0
        stage = case['stage']
        self.uc.mem_write(OBJECT, b'\xa5' * 0x30000)
        self.uc.mem_write(SCENE, b'\xa5' * 0x2000)
        # main object: chapter/selectors/flags/callbacks
        self.uc.mem_write(OBJECT + 0x13535, bytes([case['chapter']]))
        self.uc.mem_write(OBJECT + 0x13530, bytes([stage]))
        self.uc.mem_write(OBJECT + 0x13533, bytes([case['map']]))
        self.uc.mem_write(OBJECT + 0x13538 + stage * STAGE_STRIDE,
                          bytes([case['flag_a'], case['flag_b']]))
        for offset in (0x278, 0x68b5):
            self.uc.mem_write(OBJECT + offset, b'\x01')
        slots = case['slots']
        for slot, offset in zip(slots, (0x21f7c, 0x21f80, 0x21f84, 0x21f88)):
            self.uc.mem_write(OBJECT + offset, struct.pack('<I', slot))
        for slot, offset in zip(slots, (0x21f98, 0x21f9c, 0x21fa0, 0x21fa4)):
            self.uc.mem_write(OBJECT + offset, struct.pack('<I', slot))
        for slot, offset in zip(slots, (0x21fb4, 0x21fb8, 0x21fbc, 0x21fc0)):
            self.uc.mem_write(OBJECT + offset, struct.pack('<I', slot))
        self.uc.mem_write(OBJECT + 0x21f78, struct.pack('<I', case['installed']))
        # scene context: action record and player slots
        action = SCENE + 0x184c
        self.uc.mem_write(action + 0x13, bytes([case['action']]))
        self.uc.mem_write(action + 0x14, bytes([1 if case['gate'] else 0]))
        self.uc.mem_write(action + 0x0c, bytes([stage]))
        self.uc.mem_write(action + 0xa4 + stage * 4, struct.pack('<h', case['outcomes'][0]))
        self.uc.mem_write(action + 0xa6 + stage * 4, struct.pack('<h', case['outcomes'][1]))
        self.uc.mem_write(SCENE + 0x1020, b'\0' * 4)
        self.uc.mem_write(SCENE + 0x10f8, struct.pack('<I', 0x33330001))
        self.uc.mem_write(SCENE + 0x10fc + stage * 4, struct.pack('<I', 0x33330002))
        for i in range(35):
            self.uc.mem_write(SCENE + 0x106c + i * 4, struct.pack('<I', 0x33331000 + i))
        self.uc.mem_write(0x10008000, struct.pack('<3I', 0x30000000, OBJECT, SCENE))
        self.uc.reg_write(UC_X86_REG_ESP, 0x10008000)
        self.uc.reg_write(UC_X86_REG_EBP, 0)
        self.uc.emu_start(0x523380, 0x30000000, count=10000)
        if self.uc.reg_read(UC_X86_REG_EIP) != 0x30000000 or self.uc.reg_read(UC_X86_REG_ESP) != 0x10008004:
            raise RuntimeError('Chapter end did not return within bound')
        return {
            'chapter': self.uc.mem_read(OBJECT + 0x13535, 1)[0],
            'map': self.uc.mem_read(OBJECT + 0x13533, 1)[0],
            'stage': self.uc.mem_read(OBJECT + 0x13530, 1)[0],
            'flag_a': self.uc.mem_read(OBJECT + 0x13538 + stage * STAGE_STRIDE, 1)[0],
            'flag_b': self.uc.mem_read(OBJECT + 0x13539 + stage * STAGE_STRIDE, 1)[0],
            'installed': struct.unpack('<I', bytes(self.uc.mem_read(OBJECT + 0x21f78, 4)))[0],
            'cleared': [bytes(self.uc.mem_read(OBJECT + offset, 4)) == b'\0\0\0\0'
                        for offset in (0x21f7c, 0x21f80, 0x21f84, 0x21f88)],
            'backup': [struct.unpack('<I', bytes(self.uc.mem_read(OBJECT + offset, 4)))[0]
                       for offset in (0x21f98, 0x21f9c, 0x21fa0, 0x21fa4)],
            'stops': len(self.stops),
            'stop_last_two': [self.stops[-2], self.stops[-1]] if self.stops else [],
            'cleanup_stage': self.cleanup_stage,
            'cleanup_scene': self.cleanup_scene,
            'action_byte': self.uc.mem_read(SCENE + 0x184c + 0x13, 1)[0],
            'gate_byte': self.uc.mem_read(SCENE + 0x184c + 0x14, 1)[0],
        }


def native_projection(case):
    state = StoryState(chapter=case['chapter'], map=case['map'], stage=case['stage'])
    state.stages[case['stage']].flag_a = case['flag_a']
    state.stages[case['stage']].flag_b = case['flag_b']
    plan = StoryPlan()
    if not case['gate'] or case['action'] == 0:
        return {'chapter': state.chapter, 'map': state.map, 'stage': state.stage,
                'flag_a': state.stages[case['stage']].flag_a,
                'flag_b': state.stages[case['stage']].flag_b,
                'installed': case['installed'], 'cleared': [False, False, False, False],
                'backup': list(case['slots']), 'stops': 0, 'cleanup_stage': 0,
                'cleanup_scene': 0,
                'action_byte': case['action'] if not case['gate'] else 0}
    lib = library()
    if case['action'] == 2:
        stage = case['stage']
        a = (C.c_int32 * 3)(0, 0, 0)
        b = (C.c_int32 * 3)(0, 0, 0)
        a[stage] = case['outcomes'][0]
        b[stage] = case['outcomes'][1]
        outcomes = StoryOutcomes(a=a, b=b)
        status = lib.dc_story_advance(C.byref(state), C.byref(outcomes), C.byref(plan))
    else:
        status = lib.dc_story_menu_action(C.byref(state), case['action'], C.byref(plan))
    if status:
        raise RuntimeError(f'Native story plan rejected case: {status}')
    record = plan.record()
    installed = None
    for command in record['commands']:
        if command[0] == 1:  # DC_STORY_INSTALL_NEXT
            installed = command[1]
        elif command[0] == 4:  # DC_STORY_ENTER_CONFIG (FUN_0050de60, type9)
            installed = 0x0050de60
        elif command[0] == 5:  # DC_STORY_ENTER_SAVE_MENU
            installed = 0x0052e070
        elif command[0] == 6:  # DC_STORY_ENTER_FADE
            installed = 0x0051e010
    next_state = record['state']
    if case['action'] == 2:
        assert installed == CHAPTER_TABLE[case['chapter'] + 1]
    else:
        assert installed == INSTALL_KNOWN[case['action']]
    any_clear = any(command[0] == 0 for command in record['commands'])
    cleared = [any_clear, any_clear, any_clear, any_clear]
    backups = case['slots']
    stops = 0
    if case['action'] in (3, 4, 5):
        stops = 36
    return {'chapter': next_state[0], 'map': next_state[1], 'stage': next_state[2],
            'flag_a': next_state[3][case['stage']][0],
            'flag_b': next_state[3][case['stage']][1],
            'installed': installed, 'cleared': cleared,
            'backup': list(backups), 'stops': stops,
            'cleanup_stage': 1 if case['action'] == 2 else 0,
            'cleanup_scene': 1 if case['action'] == 2 else 0,
            'action_byte': 2 if case['action'] == 2 else 0}


MAP_TABLE = [0xff,0xff,0xff,0x00,0xff,0x01,0xff,0x03,0xff,0xff,0x00,0xff,0x01,
             0xff,0x06,0xff,0xff,0x00,0xff,0x01,0xff,0x04,0xff,0xff,0xff,0xff]
STAGE_TABLE = [0xff,0xff,0xff,0x02,0xff,0x02,0xff,0x02,0xff,0xff,0x01,0xff,0x01,
               0xff,0x01,0xff,0xff,0x00,0xff,0x00,0xff,0x00,0xff,0xff,0xff,0xff]


def cases():
    for chapter, stage, action, gate, oa, ob, fa, fb in product(
            (3, 10, 17, 23), range(3), (0, 2, 3, 4, 5), (0, 1),
            (0, 1, 2, 0x1234), (0, 1, 3), (0, 1), (0, 1)):
        if gate and action == 2 and chapter + 1 >= 26:
            continue
        yield {'chapter': chapter, 'map': 3, 'stage': stage, 'action': action,
               'gate': gate, 'outcomes': (oa, ob), 'flag_a': fa, 'flag_b': fb,
               'slots': (0x10101001, 0x10101002, 0x10101003, 0x10101004),
               'installed': 0x20202002, 'action_byte': action}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--vectors', type=Path, required=True)
    args = parser.parse_args()
    original = OriginalChapterEnd(args.exe)
    digest = hashlib.sha256()
    count = 0
    for case in cases():
        expected = projection(case_state(case), case['outcomes'], case['action'], case['gate'])
        observed = original.run(case)
        for key in ('chapter', 'map', 'stage', 'flag_a', 'flag_b', 'installed',
                    'cleared', 'backup', 'stops', 'cleanup_stage', 'cleanup_scene',
                    'action_byte', 'gate_byte'):
            if observed[key] != expected.get(key, observed[key]):
                raise ValueError(f'Mismatch {case}: {key} observed {observed[key]} expected {expected.get(key)}')
        native = native_projection(case)
        for key in ('chapter', 'map', 'stage', 'flag_a', 'flag_b', 'installed',
                    'cleared', 'backup', 'stops', 'cleanup_stage', 'cleanup_scene',
                    'action_byte'):
            if native[key] != observed[key]:
                raise ValueError(f'Native mismatch {case}: {key} native {native[key]} original {observed[key]}')
        digest.update((json.dumps({**{k: case[k] for k in case if k != 'slots'},
                                   'output': observed}, sort_keys=True, separators=(',', ':')) + '\n').encode())
        count += 1
    report = {'target_sha256': TARGET_SHA256,
              'original_function_sha256': original.hashes,
              'cases': count,
              'coverage': 'original chapter-end handler FUN_00523380 actions 0/2/3/4/5 with real static chapter tables; native dc_story projections compare chapter/map/stage/flags/callback installs/cleanup calls',
              'original_game_resources_used': False,
              'game_playability': 'not verified'}
    for path in (args.output, args.vectors):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'cases': count, 'original_function_sha256': original.hashes}))


def case_state(case):
    return {'chapter': case['chapter'], 'map': 3, 'stage': case['stage'],
            'flag_a': case['flag_a'], 'flag_b': case['flag_b'],
            'installed': 0x20202002, 'slots': case['slots'],
            'backup': case['slots'], 'action_byte': case['action']}


if __name__ == '__main__':
    main()
