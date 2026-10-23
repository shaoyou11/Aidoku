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
Path('build/release-notes.txt').write_text(
    'AidokuT 定制更新：书架 NAS 入口移入右上菜单，移除左上独立按钮；NAS 首页优先显示继续阅读和漫画，管理与连接详情收进二级入口；新增最近阅读、未读、已缓存筛选，并显示章节阅读进度。\n\n'
    '缓存可选 256 MB、512 MB、1 GB、2 GB，最高 2 GB。下载时同时校验声明大小与实际接收大小；降低容量不会自动删除已有章节。支持按漫画和章节管理缓存，清理前列出删除内容、保留的离线章节及可释放空间。\n\n'
    '保留上游功能、NAS 阅读、隐私过滤和双线路连接；失败时显示原因和重试入口。\n\n'
    '上游版本：'+meta['upstreamTag']+'\n定制提交：'+meta['sourceCommit']+'\n构建号：'+meta['build']+'\n\n'
    '验证：NAS 核心回归与 Release 编译通过；iPhone 18 Pro Max 模拟器正常字号下检查了容量选择与清理预览。真实手机的 NAS 续读与长时间网络切换仍需实际使用验证。\n'
    '未签名 IPA，需使用自己的证书签名。\n'
)
