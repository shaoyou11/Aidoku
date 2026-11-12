# 个人定制版本

本分支保留上游 Aidoku，并加入 NAS WebDAV 同步、远程文件夹选择、内置源列表和设置入口。

同步账号与密码由用户在 App 中配置，不包含在仓库。个人签名 Team 请在 `Aidoku/PersonalSigning.local.xcconfig` 中配置 `DEVELOPMENT_TEAM`，该文件已忽略。空的 PersonalSigning.entitlements 用于本地个人签名配置。

运行 `bash Tests/run-nas-sync.sh` 可检查同步合并、WebDAV 传输、数据库和目录解析。数据库测试需要脚本指定的已编译模型，可通过参数提供模型路径。

本地构建和测试不等于真实 NAS 连通、签名安装或实机功能验收；安装时需使用自己的签名材料。

## 个人签名更新入口

仅关于页提供“签名更新 / 安装新版”。入口由构建 Secret `AIDOKUT_UPDATE_URL` 注入，也可在设备上修改。只打开 HTTPS 个人签名工作台并定位 AidokuT，不请求官方未签名安装包。NAS 延续原 Bundle ID 签名；iOS 仍需用户确认安装，不支持静默替换应用。

## NAS 恢复与 iCloud

NAS 页面增加“从 NAS 恢复书架与进度”。此操作仅 GET 读取现有同步文档，保留本机独有条目，按时间合并重合条目，忽略远端删除标记，恢复前保存本机快照。不恢复漫画图片，也无法恢复已从同步文档删除的内容。开启前台自动同步后仍会继续双向同步。

正式开发者与内部 TestFlight 构建启用专用 CloudKit 容器；通用自签包仍由打包流程设置 `AidokuTCloudSyncDisabled`，避免缺少权限时误开启。书架与进度同一时间只使用 NAS 或 iCloud；切换 iCloud 会取消 NAS 请求并阻止旧结果回写，当前会话仍运行 CloudKit 时须重启后才能恢复 NAS 同步。NAS 漫画库的文件浏览、下载及缓存阅读独立于书架同步方式，继续可用。
