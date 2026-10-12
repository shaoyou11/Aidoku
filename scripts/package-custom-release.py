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
Path('build/release-notes.txt').write_text('AidokuT 定制更新：修复 NAS 漫画在滚动阅读中图片空白、选择漫画文件夹弹窗空白的问题。NAS 章节增加直接可见的删除按钮，保留逐章确认与文件版本校验。已有 NAS 章节自动读取 ComicInfo 标题、作者、简介及首图缩略图；补齐手机下载列表和详情的本地封面。保留 NAS 按页在线阅读、IPv6 优先及 IPv4 回退、隐私显示和签名更新。\n\n上游版本：'+meta['upstreamTag']+'\n定制提交：'+meta['sourceCommit']+'\n构建号：'+meta['build']+'\n\n未签名 IPA，需使用自己的证书签名。NAS 回归测试和实际 Nuke 图片解码检查通过；iPhone 端显示仍需更新后验证。\n')
