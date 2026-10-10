# coding: utf-8
import hashlib,json,os,plistlib,subprocess,zipfile
from pathlib import Path
app=Path('build/AidokuT.xcarchive/Products/Applications/Aidoku.app')
p=app/'Info.plist'
info=plistlib.loads(p.read_bytes())
info['CFBundleDisplayName']='AidokuT'
info['CFBundleVersion']=str(200000+int(os.environ['GITHUB_RUN_NUMBER']))
p.write_bytes(plistlib.dumps(info))
ipa=Path('build/AidokuT.ipa')
with zipfile.ZipFile(ipa,'w',compression=zipfile.ZIP_DEFLATED) as z:
    for file in sorted(app.rglob('*')):
        if file.is_file():z.write(file,Path('Payload/Aidoku.app')/file.relative_to(app))
meta={'kind':'aidokut-custom','repository':'shaoyou11/Aidoku','branch':'custom/nas-sync','sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'upstreamTag':Path('build/upstream-tag.txt').read_text(),'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'bundleId':info['CFBundleIdentifier'],'sha256':hashlib.sha256(ipa.read_bytes()).hexdigest()}
Path('build/aidokut-build.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2))
Path('build/release-notes.txt').write_text('AidokuT 自动构建的定制版本。保留 NAS WebDAV 同步、目录选择与内置源。\n\n上游版本：'+meta['upstreamTag']+'\n定制提交：'+meta['sourceCommit']+'\n构建号：'+meta['build']+'\n\n未签名 IPA，需使用自己的证书签名。NAS 数据库、同步、传输和目录解析检查通过。\n')
