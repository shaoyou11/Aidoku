# coding: utf-8
import hashlib,json,os,plistlib,subprocess,zipfile
from pathlib import Path
app=Path('build/AidokuT.xcarchive/Products/Applications/Aidoku.app')
p=app/'Info.plist'
info=plistlib.loads(p.read_bytes())
info['CFBundleDisplayName']='AidokuT'
info['AidokuTCloudSyncDisabled']=True
from urllib.parse import urlsplit
portal=os.environ.get('AIDOKUT_UPDATE_URL','').strip()
parsed=urlsplit(portal)
if parsed.scheme!='https' or not parsed.hostname or parsed.username or parsed.password:
    raise SystemExit('缺少有效的签名更新入口 Secret')
info['AidokuTUpdateURL']=portal
info['CFBundleVersion']=str(200000+int(os.environ['GITHUB_RUN_NUMBER']))
p.write_bytes(plistlib.dumps(info))
ipa=Path('build/AidokuT.ipa')
with zipfile.ZipFile(ipa,'w',compression=zipfile.ZIP_DEFLATED) as z:
    for file in sorted(app.rglob('*')):
        if file.is_file():z.write(file,Path('Payload/Aidoku.app')/file.relative_to(app))
meta={'kind':'aidokut-custom','repository':'shaoyou11/Aidoku','branch':'custom/nas-sync','sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'upstreamTag':Path('build/upstream-tag.txt').read_text(),'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'bundleId':info['CFBundleIdentifier'],'sha256':hashlib.sha256(ipa.read_bytes()).hexdigest()}
Path('build/aidokut-build.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2))
Path('build/release-notes.txt').write_text('AidokuT 定制更新：优化 iPhone 18 Pro Max 的 NAS 访问与布局：书架直达 NAS，按需读取封面与详情，管理和连接说明折叠，章节操作收进长按与左滑，增加键盘完成按钮。合并上游 v0.9-4，兼容新的历史源缓存、阅读预加载返回值和源首页布局，保留 NAS 阅读与隐私过滤。复用 NAS 阅读连接，避免逐页重复等待备用线路；将 ZIP 解压和校验移出主线程。整本漫画及空目录增加移到 NAS 回收站入口，保留文件并支持在 NAS 恢复。NAS 封面优先沿用原漫画封面，本地保存并在上传时同步封面。保留单章删除确认、按页在线阅读、隐私过滤与双线路连接。\n\n上游版本：'+meta['upstreamTag']+'\n定制提交：'+meta['sourceCommit']+'\n构建号：'+meta['build']+'\n\n未签名 IPA，需使用自己的证书签名。回归测试与 Release 编译通过；实际滚动手感需在 iPhone 更新后确认。\n')
