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
