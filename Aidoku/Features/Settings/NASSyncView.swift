import SwiftUI

struct NASSyncView: View {
    @ObservedObject private var manager = NASSyncManager.shared
    @State private var connection = NASConnection()
    @State private var automatic = false
    @State private var showFolders = false
    @State private var confirmRestore = false
    @State private var message: String?
    @State private var savedConnection = NASConnection()
    private var dirty: Bool { connection != savedConnection }

    var body: some View {
        Form {
            Section {
                TextField("WebDAV 地址（HTTPS / 局域网 HTTP）", text: $connection.folder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                TextField("用户名", text: $connection.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                SecureField("密码", text: $connection.password)
                Button("连接并选择文件夹") { showFolders = true }
                    .disabled(connection.folder.isEmpty || connection.username.isEmpty || connection.password.isEmpty)
                Button("保存连接") {
                    do {
                        try manager.saveConnection(connection)
                        savedConnection = connection
                        message = "已保存。点击“立即同步”可验证连接并合并数据。"
                    } catch {
                        message = (error as? NASSyncError)?.localizedDescription ?? "保存失败，请重试。"
                    }
                }
            } header: {
                Text("飞牛 NAS / WebDAV")
            } footer: {
                Text("填写 WebDAV 服务地址和账号，连接后可浏览或新建同步文件夹。选好后点击“保存连接”。登录信息仅保存在本机钥匙串。HTTP 仅支持局域网 IPv4 地址，账号密码及同步内容不加密，请仅在可信网络中使用专用账号。")
            }
            .disabled(manager.busy)

            Section {
                Toggle("前台自动同步", isOn: $automatic)
                    .disabled(dirty || connection.folder.isEmpty)
                    .onChange(of: automatic) { value in
                        manager.automatic = value
                        manager.stopAutomaticSync()
                        if value { manager.startAutomaticSync() }
                    }
                Button {
                    Task { await manager.sync() }
                } label: {
                    HStack {
                        Text("立即同步")
                        if manager.busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(manager.busy || dirty || connection.folder.isEmpty)
                Button("从 NAS 恢复书架与进度") { confirmRestore = true }
                    .disabled(manager.busy || dirty || connection.folder.isEmpty)
                Text(manager.status).foregroundStyle(.secondary)
                if let date = manager.lastSync {
                    Text("最近完成：\(date.formatted(date: .numeric, time: .standard))")
                        .font(.footnote)
                }
            } footer: {
                Text("打开 App 时同步，使用期间每分钟同步一次。后台不保证执行。修改连接后请先保存。")
            }
            Section {
                Text("同步书架、分类归属、章节已读状态和阅读位置。不同条目会合并，阅读进度按阅读时间处理，书架修改按本机检测到变更的时间处理。删除记录也会同步。请保持设备时间准确。")
                Text("不上传漫画文件、图源账号或密码，也不同步本地导入漫画的书架和进度。其他设备需安装相同定制版本并配置相同图源。首次合并前会保留本机数据快照。")
                Text("换机或重装后：安装相同图源 → 选择原来的 NAS 同步文件夹 → 保存连接 → 点击“从 NAS 恢复书架与进度”。漫画图片需另行下载。恢复只读取 NAS，保留本机独有条目，重合条目按时间合并。")
                if CoreDataManager.supportsCloudSync { Text("使用 NAS 同步前，请关闭 iCloud 同步。") }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            if let message { Section { Text(message).font(.footnote) } }
        }
        .navigationTitle("NAS 同步")
        .confirmationDialog("从当前 NAS 文件夹恢复？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("恢复书架与进度") { Task { await manager.sync(restoreOnly: true) } }
        } message: {
            Text("本次恢复只读取并合并，不清空本机书架，不上传覆盖 NAS；开启自动同步后仍会双向合并。恢复前保存本机快照，不恢复漫画图片或 NAS 中已删除的条目。")
        }
        .sheet(isPresented: $showFolders) {
            NASFolderPicker(connection: connection) { folder in
                connection.folder = folder.absoluteString
                message = "已选择同步文件夹，请点击“保存连接”。"
            }
        }
        .onChange(of: showFolders) { showing in
            if showing { manager.stopAutomaticSync() }
            else if automatic { manager.startAutomaticSync() }
        }
        .task {
            do {
                connection = try manager.loadConnection()
                automatic = manager.automatic
                savedConnection = connection
            } catch { message = "无法读取连接信息，请解锁设备后重试。" }
        }

    }
}
