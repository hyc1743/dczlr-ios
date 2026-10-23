"""Generate tiny public fixtures for the actual Swift resource importer gate."""
import argparse
from pathlib import Path
import shutil
from pack_resources import pack


def generate(root):
    if root.exists():raise ValueError('Importer fixture root must be new')
    source=root/'source';source.mkdir(parents=True)
    (source/'save').mkdir()
    (source/'a.bin').write_bytes(bytes(range(150)))
    (source/'save/RP_00.sav').write_bytes(b'default-save')
    (source/'settings.cfg').write_bytes(b'default-settings')
    manifest=pack(source,root/'ResourcePacks',64)
    if len(manifest['parts'])!=3:raise ValueError('Expected exactly three synthetic parts')
    shutil.copyfile(root/'ResourcePacks/DczlrData.manifest.json',root/'DczlrData.manifest.json')
    shutil.move(root/'ResourcePacks/DczlrData.part001.dczdata',root/'DczlrData.part001.dczdata')
    (root/'.portlab-import-fixture').write_text('self-authored-only\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();generate(args.output)
    print('Generated self-authored three-part importer fixture')
