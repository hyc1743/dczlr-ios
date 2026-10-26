"""Synthetic chapter descriptors and adventure transition action states."""
import ctypes as C
from itertools import product
from native_core import IntroState,IntroDescriptor,IntroPlan


def table():return [[i%19,5+i] for i in range(26)]


def finish_cases():
    for chapter,progress,script in product(range(27),(0,1,2),(0,1,2,5,8,13,-1)):
        descriptors=table()
        if chapter<25:descriptors[chapter+1]=[script,5 if script>=0 else -1]
        yield {'state':[chapter,0,0,progress],'table':descriptors}


def transition_cases():
    for chapter,action,waiting,progress,ready in product(range(27),range(8),range(2),(0,1,2),range(2)):
        if chapter==26 and action in (1,4):continue
        yield {'state':[chapter,action,waiting,progress],'table':table(),'ready':ready}


def native_result(lib,case,finish=False):
    s=IntroState(*case['state']);descriptors=(IntroDescriptor*26)(*(IntroDescriptor(*v) for v in case['table']));p=IntroPlan()
    if finish:status=lib.dc_intro_finish(C.byref(s),descriptors,26,C.byref(p))
    else:status=lib.dc_intro_transition(C.byref(s),descriptors,26,case['ready'],C.byref(p))
    if status:raise ValueError(f'Native intro plan rejected case: {status}')
    return p.record()


# Real chapter descriptors recovered from 0x0078d908.
REAL_TABLE = [[0,2],[1,31],[2,9],[-1,-1],[15,2],[-1,-1],[3,38],[-1,-1],
              [4,31],[5,5],[-1,-1],[16,2],[-1,-1],[6,42],[-1,-1],[7,43],
              [8,4],[-1,-1],[9,4],[-1,-1],[10,51],[-1,-1],[11,74],[13,4],
              [-1,-1],[12,13]]


def real_table():
    return [list(row) for row in REAL_TABLE]


def real_finish_cases():
    for chapter in range(26):
        for progress in (0, 1, 2):
            yield {'state': [chapter, 0, 0, progress], 'table': real_table()}


def real_transition_cases():
    for chapter, action, waiting, progress, ready in product(
            range(27), range(8), range(2), (0, 1, 2), range(2)):
        if chapter == 26 and action in (1, 4):
            continue
        # Action 4 is only installed by the original finish for script
        # chapters whose next descriptor is one of 1/5/8/13.
        if action == 4 and (chapter >= 26 or REAL_TABLE[chapter][0] not in (1, 5, 8, 13)):
            continue
        yield {'state': [chapter, action, waiting, progress], 'table': real_table(), 'ready': ready}
