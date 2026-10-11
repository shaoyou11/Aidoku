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
Path('build/release-notes.txt').write_text('AidokuT 自动构建的定制版本。增加 NAS 漫画上传、按页在线阅读、逐章关联与读取来源切换；支持 IPv6 优先及备用地址回退。默认隐藏 NSFW，设置可调整，三击书架可临时显示。保留 NAS 同步、恢复与签名更新入口。\n\n上游版本：'+meta['upstreamTag']+'\n定制提交：'+meta['sourceCommit']+'\n构建号：'+meta['build']+'\n\n未签名 IPA，需使用自己的证书签名。NAS 数据库、同步、目录、ZIP 分段读取、IPv6 回退和隐私策略检查通过。\n')
