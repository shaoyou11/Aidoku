"""Fail closed when a merge removes the personal NAS/cloud/privacy/UI contract."""
from pathlib import Path
import hashlib, json, subprocess, sys
root=Path(__file__).resolve().parents[1]

def check(condition,message):
    if not condition: raise SystemExit(message)

def text(path): return (root/path).read_text()

def protected(path):
    return (path.startswith('Aidoku/Core/Sync/NAS') or path.startswith('Aidoku/Core/Privacy/')
        or path.startswith('Aidoku/Features/Settings/NAS') or path.startswith('Aidoku/App/Resources/AppIcon.icon/')
        or path.startswith('Aidoku/App/Resources/Assets.xcassets/AppIcon.appiconset/')
        or path.startswith('.github/workflows/') or path.startswith('ci_scripts/')
        or path in ['PersonalSigning.entitlements','Aidoku/Aidoku.xcconfig',
                    'Aidoku/Core/Database/CoreDataManager.swift','Aidoku/App/Root/TabBarController.swift',
                    'Aidoku.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'])

def snapshot():
    files=subprocess.check_output(['git','ls-files','-z'],cwd=root).decode().split('\0')
    return {p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in files if p and protected(p) and (root/p).is_file()}

if len(sys.argv)>1 and sys.argv[1]=='snapshot':
    Path(sys.argv[2]).write_text(json.dumps(snapshot(),sort_keys=True));sys.exit(0)
if len(sys.argv)>1 and sys.argv[1]=='compare':
    before=json.loads(Path(sys.argv[2]).read_text());after=snapshot()
    changed=sorted(p for p,h in before.items() if after.get(p)!=h)
    check(not changed,'受保护定制文件有变化，停止自动发布：\n'+'\n'.join(changed))

nas=text('Aidoku/Core/Sync/NASSyncManager.swift')
check('usesCloudKitMirroring' in nas and 'icloudSync.get()' in nas,'NAS 与 iCloud 互斥保护缺失')
privacy=text('Aidoku/Core/Privacy/PrivacyDisplayStore.swift')
check('UIApplication.didEnterBackgroundNotification' in privacy and 'self?.hideAgain()' in privacy,'后台自动隐藏保护缺失')
check('libraryTabTapped' in privacy and 'temporarilyRevealed.toggle()' in privacy,'三击临时显示保护缺失')
manga=text('Aidoku/Features/Manga/MangaView.swift')
check('if !privacy.allows(viewModel.manga)' in manga and 'Color(uiColor: ShelfPageBackground.color).ignoresSafeArea()' in manga,'漫画隐私遮挡缺失')
check('此漫画已隐藏' not in manga and '连续三击底部书架' not in manga,'隐私遮挡不应暴露状态或手势提示')
lib=text('Aidoku/Features/Library/LibraryViewController.swift')
check('shelfTitleView' in lib and 'setShelfRefreshProgress' in lib and 'makeShelfMenu()' in lib,'书架标题、菜单或刷新状态定制缺失')
tab=text('Aidoku/App/Root/TabBarController.swift')
check('libraryRefreshAccessory' not in tab and 'libraryRootViewController?.setShelfRefreshProgress' in tab,'刷新状态不应返回底部遮挡书架')
check('chromeAnimator.isReversed' in tab or 'animator.isReversed' in tab,'底栏可中断动画定制缺失')
icon=json.loads(text('Aidoku/App/Resources/AppIcon.icon/icon.json'))
check(icon['fill']['solid']=='srgb:0.00000,0.00000,0.00000,1.00000','黑色图标配置缺失')
check(icon['groups'][0]['layers'][0]['image-name']=='BlackAidoku.png','新图标资源未启用')
print('PASS: NAS/iCloud exclusion, privacy cover and triple-tap state, title refresh/menu, reversible tab animation and black icon')
