"""Exercise real Git merges against isolated local upstreams; never touch user data or network."""
from pathlib import Path
import os, shutil, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]

def git(root,*args):
 return subprocess.check_output(['git','-C',str(root),*args],stderr=subprocess.DEVNULL,text=True).strip()

def scenario(kind):
 folder=Path(tempfile.mkdtemp(prefix='aidokut-auto-merge-'));base=folder/'base';base.mkdir()
 files=['scripts/check_customizations.py','scripts/prepare-upstream-sync.sh','Aidoku/Core/Sync/NASSyncManager.swift',
 'Aidoku/Core/Privacy/PrivacyDisplayStore.swift','Aidoku/Core/Privacy/PrivacyDisplayPolicy.swift',
 'Aidoku/Features/Manga/MangaView.swift','Aidoku/Features/Library/LibraryViewController.swift',
 'Aidoku/App/Root/TabBarController.swift','Aidoku/App/Resources/AppIcon.icon/icon.json',
 'PersonalSigning.entitlements','Aidoku/Core/Database/CoreDataManager.swift']
 for f in files:
  dst=base/f;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/f,dst)
 (base/'upstream-feature.txt').write_text('base\n')
 git(base,'init','-b','main');git(base,'config','user.name','Fixture');git(base,'config','user.email','fixture@example.invalid')
 git(base,'add','.');git(base,'commit','-m','fixture')
 remote=folder/'upstream.git';git(folder,'clone','--bare',str(base),str(remote))
 work=folder/'custom';git(folder,'clone',str(remote),str(work));git(work,'checkout','-b','custom/nas-sync')
 git(work,'config','user.name','Fixture');git(work,'config','user.email','fixture@example.invalid')
 git(work,'config',f'url.{remote}.insteadOf','https://github.com/Aidoku/Aidoku.git')
 if kind=='conflict':
  (work/'upstream-feature.txt').write_text('custom\n');git(work,'add','.');git(work,'commit','-m','custom')
 before=git(work,'rev-parse','HEAD')
 if kind=='protected':
  p=base/'Aidoku/App/Root/TabBarController.swift';p.write_text(p.read_text()+'\n// upstream change\n')
 elif kind=='conflict':(base/'upstream-feature.txt').write_text('upstream\n')
 elif kind=='clean':(base/'new-upstream-feature.txt').write_text('new\n')
 if kind!='unchanged':
  git(base,'add','.');git(base,'commit','-m','upstream');git(base,'push',str(remote),'main')
 out=folder/'output';out.write_text('')
 result=subprocess.run(['bash','scripts/prepare-upstream-sync.sh'],cwd=work,env=os.environ|{'GITHUB_REPOSITORY':'shaoyou11/Aidoku','GITHUB_OUTPUT':str(out)},capture_output=True,text=True,errors="replace")
 after=git(work,'rev-parse','HEAD');data=out.read_text()
 if kind=='clean':
  assert result.returncode==0 and after!=before and 'changed=true' in data,(kind,result.stderr,result.stdout)
  assert (work/'new-upstream-feature.txt').read_text()=='new\n'
 elif kind=='unchanged':assert result.returncode==0 and after==before and 'changed=false' in data
 else:assert result.returncode!=0 and after==before and 'changed=true' not in data,(kind,result.stdout)
 print('PASS: upstream sync',kind)

for kind in ['clean','unchanged','protected','conflict']:scenario(kind)
