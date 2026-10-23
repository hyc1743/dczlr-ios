"""Self-authored title action/input combinations; no executable dependency."""
import ctypes as C
from itertools import product
from native_core import TitleState,TitleInput,TitlePlan


def cases():
    menus=[(-1,-1)]+[(result,row) for result,row in product(range(4),range(5))]
    for action,waiting,hover,ready,busy,escape,menu in product(range(7),range(2),(0,4,255),range(2),range(2),(0,2,3),menus):
        yield {'state':[action,waiting,hover],'input':[ready,busy,escape,*menu]}


def native_result(lib,case):
    state=TitleState(*case['state']);input=TitleInput(*case['input']);out=TitlePlan()
    status=lib.dc_title_build_plan(C.byref(state),C.byref(input),C.byref(out))
    if status:raise ValueError(f'Title planner rejected case: {status}')
    return out.record()
