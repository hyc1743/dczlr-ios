"""Independent scalar camera calculations for captured-render verification."""
import math

def orbit_world(pose):
    height,distance,pitch,yaw,x,y,z=pose
    sx,cx,sy,cy=math.sin(pitch),math.cos(pitch),math.sin(yaw),math.cos(yaw)
    rows=[cy,0,-sy,0,sx*sy,cx,sx*cy,0,cx*sy,-sx,cx*cy,0]
    return rows+[x-distance*rows[8],y+height-distance*rows[9],z-distance*rows[10],1]

def multiply(a,b):
    return [sum(a[r*4+k]*b[k*4+c] for k in range(4)) for r in range(4) for c in range(4)]

def look_at_world(eye,target):
    def normalized(v):
        length=math.sqrt(sum(x*x for x in v))
        if not math.isfinite(length) or not length:raise ValueError('Degenerate camera vector')
        return [x/length for x in v]
    back=normalized([a-b for a,b in zip(eye,target)])
    right=normalized([back[2],0,-back[0]])
    up=[back[1]*right[2]-back[2]*right[1],back[2]*right[0]-back[0]*right[2],back[0]*right[1]-back[1]*right[0]]
    return [*right,0,*up,0,*back,0,*eye,1]
