# 个人定制版本

本分支保留上游 Aidoku，并加入 NAS WebDAV 同步、远程文件夹选择、内置源列表和设置入口。

同步账号与密码由用户在 App 中配置，不包含在仓库。个人签名 Team 请在 `Aidoku/PersonalSigning.local.xcconfig` 中配置 `DEVELOPMENT_TEAM`，该文件已忽略。空的 PersonalSigning.entitlements 用于本地个人签名配置。

运行 `bash Tests/run-nas-sync.sh` 可检查同步合并、WebDAV 传输、数据库和目录解析。数据库测试需要脚本指定的已编译模型，可通过参数提供模型路径。

本地构建和测试不等于真实 NAS 连通、签名安装或实机功能验收；安装时需使用自己的签名材料。
