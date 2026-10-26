"""Validate exact GPU checkpoints, including visibility after depth testing."""
import hashlib
import math
from pathlib import Path
from startup_pixels import decode

CHAPTER_MAPS={3:0,5:1,7:3,14:6,21:4}
SAMPLES=('idle','interaction','restored')

def validate(report,root):
    root=Path(root).resolve()
    if report.get('kind')!='deterministic_render_checkpoints' or report.get('playability_certification') is not False:
        raise ValueError('Render checkpoints must be separate from playability certification')
    captures=report.get('captures',[])
    if len(captures)!=len(CHAPTER_MAPS)*len(SAMPLES):
        raise ValueError('Missing per-scene or interaction captures')
    seen={};results=[]
    for row in captures:
        chapter,sample=row.get('chapter'),row.get('sample')
        key=(chapter,sample)
        if chapter not in CHAPTER_MAPS or sample not in SAMPLES or key in seen:
            raise ValueError('Unknown or duplicate render checkpoint')
        if row.get('map')!=CHAPTER_MAPS[chapter] or not row.get('anchor') or not row.get('camera'):
            raise ValueError('Scene placement/camera metadata is missing or mismatched')
        if row.get('depth_policy')!='material_auto':raise ValueError('Scene did not use material-aware depth')
        active=row.get('interaction_active')
        if active is not (sample=='interaction'):
            raise ValueError('Interaction frame was captured in the wrong state')
        if sample=='restored' and not row.get('interaction_completed'):
            raise ValueError('Interaction did not restore the normal scene')
        filename=row.get('file','')
        if filename!=f'render-c{chapter:02d}-{sample}.png':raise ValueError('Capture is not bound to its scene/sample')
        path=(root/filename).resolve()
        if not path.is_relative_to(root):raise ValueError('Invalid capture path')
        image=path.read_bytes();w,h,channels,pixels=decode(image)
        if (w,h)!=(row.get('width'),row.get('height')):raise ValueError('Capture dimensions differ from GPU metadata')
        if channels==4 and min(pixels[3::4])!=255:raise ValueError('Opaque presentation was saved with blended target alpha')
        area=row.get('viewport_pixels',0);visible=row.get('actor_visible_pixels',0)
        bbox=row.get('actor_bbox',[])
        if not isinstance(area,(int,float)) or not math.isfinite(area) or not 0<area<=w*h+1:
            raise ValueError('Invalid scene viewport area')
        if not area*.003<=visible<=area or len(bbox)!=4:
            raise ValueError(f'Actor occluded or absent in chapter {chapter} / {sample}: {visible} pixels')
        x0,y0,x1,y1=bbox
        if not (0<=x0<=x1<w and 0<=y0<=y1<h and y1-y0>=h*.2):
            raise ValueError('Only a fragment of the actor survived depth testing')
        pose=row.get('pose_frame')
        if not isinstance(pose,(int,float)) or not math.isfinite(pose):raise ValueError('Missing animation sample')
        seen[key]={**row,'sha256':hashlib.sha256(image).hexdigest(),'actor_ratio':visible/area}
    for chapter,map_selector in CHAPTER_MAPS.items():
        group=[seen[(chapter,sample)] for sample in SAMPLES]
        if group[0]['sha256']==group[1]['sha256']:
            raise ValueError('Interaction capture did not change the rendered frame')
        results.append({'chapter':chapter,'map':map_selector,'anchor':group[0]['anchor'],'camera':group[0]['camera'],
                        'minimum_actor_ratio':min(r['actor_ratio'] for r in group),
                        'samples':[{'sample':r['sample'],'actor_visible_pixels':r['actor_visible_pixels'],
                                    'pose_frame':r['pose_frame'],'sha256':r['sha256']} for r in group]})
    return {'gpu_checkpoints':len(seen),'scenes':results,
            'visibility':'full scene versus identical GPU background with actor omitted; depth-tested RGB contribution',
            'input':'deterministic render checkpoints; not a substitute for the visible-touch test',
            'original_image_equivalence':'not established','physical_device':'not tested'}
