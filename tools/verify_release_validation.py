"""Bind a development release to the scoped simulator run and runtime source."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
from github_transport import request

RUNTIME_PATHS=['native','ios/Native','ios/Sources','ios/RuntimeChecks','ios/Resources',
               'tools/bootstrap_moltenvk.py','tools/build_sprite_shaders.py','tools/check_ios_sprite.py',
               'tools/camera_evidence_math.py','tools/secondary_camera_evidence.py']
def check(run,jobs,allow_bounded=False):
    if run['path']!='.github/workflows/build-ios.yml' or run['status']!='completed' or run['conclusion']!='success':
        raise ValueError('A successful iOS validation workflow is required')
    for name in ('portable','ios'):
        if not any(j['name']==name and j['conclusion']=='success' for j in jobs):raise ValueError('Missing successful '+name+' job')
    required={'Launch the Vulkan sprite scene on iPhone simulator','Exercise startup and New Game with generated resources',
              'Exercise simultaneous keyboard and mouse controls'}
    if not allow_bounded:
        required.add('Verify virtual mouse on the first real scene')
    passed={s['name'] for j in jobs for s in j.get('steps',[]) if s['conclusion']=='success'}
    if not required<=passed:raise ValueError('Missing scoped simulator execution checks')
    return {'run':run['id'],'source':run['head_sha'],'scope':'startup, PC/touch input and simulator compilation; real-resource virtual-mouse route was not run in this validation',
            'complete_story':'not tested','physical_device':'not tested'}
def normalized_project(text):
    return re.sub(r'(CFBundle(?:ShortVersionString|Version):)\s*"[^"\n]+"',r'\1 "VERSION"',text)
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--run',type=int,required=True);p.add_argument('--tag',required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if not re.fullmatch(r'v\d+\.\d+\.\d+',a.tag):raise ValueError('Expected a numeric release tag')
    repo=os.environ['GITHUB_REPOSITORY'];token=os.environ['GH_TOKEN'];base='/repos/'+repo
    run=request(token,'GET',base+'/actions/runs/'+str(a.run));jobs=request(token,'GET',base+'/actions/runs/'+str(a.run)+'/jobs?per_page=100')['jobs']
    evidence=check(run,jobs,allow_bounded=True)
    subprocess.run(['git','diff','--exit-code',run['head_sha'],'HEAD','--',*RUNTIME_PATHS],check=True)
    original=subprocess.check_output(['git','show',run['head_sha']+':ios/project.yml'],text=True)
    current=Path('ios/project.yml').read_text(encoding='utf-8')
    if normalized_project(original)!=normalized_project(current):raise ValueError('Build configuration changed beyond version numbers')
    if 'CFBundleShortVersionString: "'+a.tag[1:]+'"' not in current:raise ValueError('Release tag and app version differ')
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(evidence))
if __name__=='__main__':main()
