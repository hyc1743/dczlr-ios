"""Verify actual secondary-view captures, not just controller mode writes."""
import math
import struct
from camera_evidence_math import orbit_world,multiply,look_at_world

STEMS=('face','body','auto-first','auto-later','auto-off','hidden','visible','pointer','right','pan','wheel')

def finite(frame,key,count):
    values=frame.get(key,[])
    if len(values)!=count or not all(isinstance(v,(int,float)) and math.isfinite(v) for v in values):
        raise ValueError('Invalid secondary camera '+key)
    return values

def close(a,b):return len(a)==len(b) and all(abs(x-y)<4e-5*(1+abs(y)) for x,y in zip(a,b))
def f32(value):return struct.unpack('<f',struct.pack('<f',value))[0]

def pointer_result(frame):
    base=finite(frame,'secondary_pointer_before_base',16)[:]
    height,distance,pitch,yaw=finite(frame,'secondary_pointer_before_pose',4)
    dx,dy,wheel,left,right,middle,fast=finite(frame,'secondary_pointer_input',7)
    if any(v!=int(v) or not -2147483648<=v<=2147483647 for v in (dx,dy,wheel)) or any(v not in (0,1,2,3) for v in (left,right,middle)) or fast not in (0,1):
        raise ValueError('Invalid pointer event bytes')
    far,near,high,low,step=finite(frame,'secondary_pointer_limits',5)
    speed=2 if fast else 1
    operation=(2 if int(right)&1 else 0) if int(left)&1 else (1 if int(right)&1 else (2 if int(middle)&1 else (3 if wheel else -1)))
    if operation==0:
        pitch=f32(pitch-dy*f32(.01)*speed);yaw=f32(yaw-dx*f32(.01)*speed)
        def angle(v):return f32(v+f32(2*math.pi)) if v<0 else f32(v-f32(2*math.pi)) if v>f32(2*math.pi) else v
        pitch,yaw=angle(pitch),angle(yaw)
    elif operation==1:
        distance=max(-far,min(-near,f32(distance-dx*f32(.1)*speed)))
        height=max(low,min(high,f32(height-dy*f32(.1)*speed)))
    elif operation>=2:
        world=multiply(orbit_world([height,distance,pitch,yaw,0,0,0]),base)
        x=f32(dx*f32(.1)*speed) if operation==2 else 0
        z=f32(dy*f32(.1)*speed) if operation==2 else f32((-1 if wheel>0 else 1)*step*speed)
        for i in range(3):base[12+i]=max(-50,min(50,f32(base[12+i]+f32(x*world[i]+z*world[8+i]))))
    return operation,[height,distance,pitch,yaw,*base[12:15]]

def validate(frames,expected_pose):
    primary=orbit_world(expected_pose)
    for name,frame in frames.items():
        if frame.get('primary_actor_visible_pixels',0)<1:raise ValueError('Primary actor missing in '+name)
        if frame.get('secondary_changed_outside')!=0:raise ValueError('Secondary pass changed pixels outside its viewport')
        viewport=finite(frame,'secondary_viewport',6);scale=frame['width']/1024
        expected=[0,int(504*scale),int(352*scale),int(264*scale),0,1]
        if not close(viewport,expected):raise ValueError('Secondary viewport differs from original slot0')
        if name!='both' and not close(finite(frame,'camera_world',16),primary):raise ValueError('Secondary input changed the primary camera')
        if name=='hidden':
            if frame.get('secondary_visible') not in (False,0) or frame.get('secondary_scene_draws')!=0 or frame.get('secondary_visible_pixels')!=0:
                raise ValueError('V did not hide the secondary pass')
            continue
        if not frame.get('secondary_visible') or frame.get('secondary_visible_pixels',0)<100:
            raise ValueError('Secondary view is not visible in actual GPU readback: '+name)
        if name not in ('pointer','right','pan','wheel') and frame.get('secondary_actor_visible_pixels',0)<1:
            raise ValueError('Secondary actor missing in '+name)
        if name not in ('pointer','right','pan','wheel') and frame.get('secondary_scene_draws',0)<=frame.get('secondary_map_draws',0):
            raise ValueError('Secondary actor geometry was not submitted in '+name)
    for name,binding in (('face',0),('body',1)):
        frame=frames[name];target=finite(frame,'secondary_target_matrix',16)
        if frame.get('secondary_target_binding')!=binding or frame['camera_modes'][1]!=binding:
            raise ValueError('Wrong original secondary binding')
        pose=finite(frame,'secondary_pose',7)
        if pose[0]!=0 or not close(pose[4:],target[12:15]):raise ValueError('Secondary retarget did not reanchor its controller')
        if not close(finite(frame,'secondary_world',16),orbit_world(pose)):raise ValueError('Secondary retarget was not rendered')
    first,later=frames['auto-first'],frames['auto-later']
    for frame in (first,later,frames['both']):
        eye=finite(frame,'automatic_eye_world',16)[12:15];target=finite(frame,'automatic_target',3)
        if frame['camera_modes'][1]!=2 or frame.get('camera_animation_clip')!=0:raise ValueError('Secondary automatic state is inactive')
        if not close(finite(frame,'secondary_world',16),look_at_world(eye,target)):raise ValueError('Secondary automatic view differs from original look-at')
    if later['secondary_auto_frames']<=first['secondary_auto_frames'] or max(abs(a-b) for a,b in zip(first['secondary_world'][12:15],later['secondary_world'][12:15]))<.001:
        raise ValueError('Secondary automatic camera is frozen')
    both=frames['both']
    if both['camera_modes']!=[2,2] or not close(both['camera_world'],both['secondary_world']):raise ValueError('Both automatic cameras did not use the same original animation frame')
    for name in ('auto-off','visible','reset'):
        if not close(finite(frames[name],'secondary_world',16),primary):raise ValueError('Original secondary CAM was not restored')
    for name,operation in (('pointer',0),('right',1),('pan',2),('wheel',3)):
        frame=frames[name];actual=finite(frame,'secondary_controller_pose',7);op,expected=pointer_result(frame)
        if op!=operation or frame.get('secondary_pointer_operation')!=operation or not close(actual,expected):
            raise ValueError('Secondary pointer result differs from original calculation: '+name)
        if not close(finite(frame,'secondary_world',16),orbit_world(actual)):raise ValueError('Pointer controller was not rendered')
    if finite(frames['pointer'],'pointer_logical',2)[0]<=352 or frames['pointer'].get('secondary_pointer_owner')!=2:
        raise ValueError('Secondary drag ownership was not preserved outside the inset')
    if frames['pan']['secondary_pointer_input'][-1]!=1:raise ValueError('F1 sensitivity modifier was not exercised')
    return {'viewport':'original logical (0,504,352,264), integer-scaled slot0',
            'rendering':'separate color/depth clear; actor GPU difference against map-only; zero changed pixels outside inset',
            'targets':'both original bindings retargeted and rendered','automatic':'animated, toggled off, and simultaneous with primary',
            'input':'V hide/show, held left outside inset, right, both buttons with F1, wheel; primary camera preserved',
            'system_screens':'not tested','complete_story':'not tested','physical_device':'not tested'}
