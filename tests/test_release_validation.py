from pathlib import Path
import copy
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from verify_release_validation import check,normalized_project

class ReleaseValidationTests(unittest.TestCase):
    def fixture(self):
        run={'id':40413204123,'path':'.github/workflows/build-ios.yml','head_sha':'verified','status':'completed','conclusion':'success'}
        steps=['Launch the Vulkan sprite scene on iPhone simulator','Exercise startup and New Game with generated resources',
            'Exercise simultaneous keyboard and mouse controls','Verify virtual mouse on the first real scene']
        jobs=[{'name':'portable','conclusion':'success','steps':[]},
              {'name':'ios','conclusion':'success','steps':[{'name':s,'conclusion':'success'} for s in steps]}]
        return run,jobs
    def test_scoped_checks_preserve_full_story_and_device_limits(self):
        run,jobs=self.fixture();result=check(run,jobs)
        self.assertEqual(result['source'],'verified');self.assertEqual(result['complete_story'],'not tested')
        self.assertEqual(result['physical_device'],'not tested')
    def test_skipped_camera_check_or_failed_workflow_cannot_certify_release(self):
        run,jobs=self.fixture()
        for changed in ('step','workflow','job','path'):
            r=copy.deepcopy(run);j=copy.deepcopy(jobs)
            if changed=='step':j[1]['steps'][-1]['conclusion']='skipped'
            if changed=='workflow':r['conclusion']='failure'
            if changed=='job':j[0]['conclusion']='failure'
            if changed=='path':r['path']='other.yml'
            with self.assertRaises(ValueError):check(r,j)
    def test_only_version_values_are_ignored_in_project_comparison(self):
        old='CFBundleShortVersionString: "0.1.9"\nCFBundleVersion: "10"\nsetting: original\n'
        new=old.replace('0.1.9','0.1.10').replace('"10"','"11"')
        self.assertEqual(normalized_project(old),normalized_project(new))
        self.assertNotEqual(normalized_project(old),normalized_project(new.replace('original','changed')))
if __name__=='__main__':unittest.main()
