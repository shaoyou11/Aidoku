import SwiftUI

struct NASSyncView: View {
    @ObservedObject private var manager = NASSyncManager.shared
    @State private var connection = NASConnection()
    @State private var editingConnection = true
    @FocusState private var focusedField: ConnectionField?
    private enum ConnectionField: Hashable { case primary, fallback, username, password }
    @State private var automatic = false
    @State private var showFolders = false
    @State private var confirmRestore = false
    @State private var message: String?
    @State private var saveSucceeded = false
    @State private var restoring = false
    @State private var savedConnection = NASConnection()
    private var dirty: Bool { connection != savedConnection }

    var body: some View {
        Form {
            Section {
                DisclosureGroup(isExpanded: $editingConnection) {
                    TextField("优先地址（IPv6 / 域名）", text: $connection.folder)
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .primary)
                        .submitLabel(.next).onSubmit { focusedField = .fallback }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                    TextField("备用地址（IPv4 / 域名，可留空）", text: Binding(get: { connection.fallbackFolder ?? "" }, set: { connection.fallbackFolder = $0 }))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        .focused($focusedField, equals: .fallback)
                        .submitLabel(.next).onSubmit { focusedField = .username }
                    Toggle("允许 IPv6 HTTP 直连（不加密）", isOn: Binding(get: { connection.allowIPv6HTTP == true }, set: { connection.allowIPv6HTTP = $0 }))
                    TextField("用户名", text: $connection.username)
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next).onSubmit { focusedField = .password }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                    SecureField("密码", text: $connection.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.done).onSubmit { focusedField = nil }
                    Button { showFolders = true } label: {
                        NASActionLabel(title: "连接并选择文件夹", systemImage: "folder")
                    }
                        .disabled(connection.folder.isEmpty || connection.username.isEmpty || connection.password.isEmpty)
                    Button {
                        do {
                            try manager.saveConnection(connection)
                            if dirty { NASConnectionStatus.shared.reset() }
                            savedConnection = connection
                            saveSucceeded = true
                            message = "连接已保存在本机，尚未验证。可选择文件夹检查连接，或点击“立即同步”。"
                        } catch {
                            saveSucceeded = false
                            message = (error as? NASSyncError)?.localizedDescription ?? "保存失败，请重试。"
                        }
                    } label: {
                        NASActionLabel(title: saveSucceeded && !dirty ? "已保存连接" : "保存连接", systemImage: saveSucceeded && !dirty ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    if let message {
                        Label(message, systemImage: saveSucceeded ? "checkmark.circle.fill" : "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } label: {
                    Label("连接设置", systemImage: "link")
                }
            } header: {
                Text("飞牛 NAS / WebDAV")
            } footer: {
                Text(connection.allowIPv6HTTP == true ? "两个地址须对应同一 NAS 的同一文件夹。HTTP 会明文传输账号及内容。" : "两个地址须对应同一 NAS 的同一文件夹，修改后请先保存。")
            }
            .disabled(manager.busy)

            NASConnectionStatusSection()

            Section {
                Toggle("前台自动同步", isOn: $automatic)
                    .disabled(dirty || connection.folder.isEmpty)
                    .onChange(of: automatic) { value in
                        manager.automatic = value
                        manager.stopAutomaticSync()
                        if value { manager.startAutomaticSync() }
                    }
                Button {
                    restoring = false
                    Task { await manager.sync() }
                } label: {
                    NASActionLabel(title: manager.busy && !restoring ? "正在同步…" : "立即同步", systemImage: "arrow.triangle.2.circlepath", busy: manager.busy && !restoring)
                }
                .disabled(manager.busy || dirty || connection.folder.isEmpty)
                Button { confirmRestore = true } label: {
                    NASActionLabel(title: manager.busy && restoring ? "正在恢复…" : "从 NAS 恢复书架与进度", systemImage: "arrow.down.circle", busy: manager.busy && restoring)
                }
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
                NavigationLink { NASComicLibraryView() } label: {
                    Label("NAS 漫画库", systemImage: "externaldrive.fill")
                }
            } footer: { Text("漫画文件独立管理：上传已下载章节、浏览 NAS 目录、缓存阅读。书架与进度同步不包含漫画图片。") }
            Section {
                DisclosureGroup {
                    Text("填写 WebDAV 服务地址和账号，连接后可浏览或新建同步文件夹。选好后点击“保存连接”。两个地址须指向同一 NAS 的同一文件夹；优先连接第一个，网络失败后用备用地址。只填一个则不切换。IPv6 字面地址用方括号包围，HTTPS 域名须匹配证书。登录信息仅保存在本机钥匙串；开启 HTTP 直连会明文传输账号及内容。")
                    Text("同步书架、分类归属、章节已读状态和阅读位置。不同条目会合并，阅读进度按阅读时间处理，书架修改按本机检测到变更的时间处理。删除记录也会同步。请保持设备时间准确。")
                    Text("不上传漫画文件、图源账号或密码，也不同步本地导入漫画的书架和进度。其他设备需安装相同定制版本并配置相同图源。首次合并前会保留本机数据快照。")
                    Text("换机或重装后：安装相同图源 → 选择原来的 NAS 同步文件夹 → 保存连接 → 点击“从 NAS 恢复书架与进度”。漫画图片需另行下载。恢复只读取 NAS，保留本机独有条目，重合条目按时间合并。")
                    if CoreDataManager.supportsCloudSync { Text("使用 NAS 同步前，请关闭 iCloud 同步。") }
                } label: {
                    Text("同步说明与恢复方法").font(.body)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(NASActionButtonStyle())
        .navigationTitle("NAS 同步")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        .confirmationDialog("从当前 NAS 文件夹恢复？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("恢复书架与进度") {
                restoring = true
                Task {
                    await manager.sync(restoreOnly: true)
                    restoring = false
                }
            }
        } message: {
            Text("本次恢复只读取并合并，不清空本机书架，不上传覆盖 NAS；开启自动同步后仍会双向合并。恢复前保存本机快照，不恢复漫画图片或 NAS 中已删除的条目。")
        }
        .sheet(isPresented: $showFolders) {
            NASFolderPicker(connection: connection) { folder in
                if let secondary = try? connection.fallbackURL(), var components = URLComponents(url: secondary, resolvingAgainstBaseURL: false) {
                    components.path = folder.path
                    connection.fallbackFolder = components.url?.absoluteString
                }
                connection.folder = folder.absoluteString
                saveSucceeded = false
                message = "已选择同步文件夹，请点击“保存连接”。"
            }
        }
        .onChange(of: connection) { _ in
            if dirty && saveSucceeded {
                saveSucceeded = false
                message = "连接信息已修改，请重新保存。"
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
                editingConnection = connection.folder.isEmpty
            } catch { message = "无法读取连接信息，请解锁设备后重试。" }
        }

    }
}
