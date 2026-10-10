import SwiftUI

struct NASFolderPicker: View {
    let connection: NASConnection
    let onSelect: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var target: URL?
    @State private var loaded: URL?
    @State private var folders: [NASFolder] = []
    @State private var busy = false
    @State private var message: String?
    @State private var newName = "Aidoku同步"

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(loaded?.path ?? target?.path ?? "正在连接…")
                        .font(.footnote)
                        .textSelection(.enabled)
                    if let target, target.path != "/" && !target.path.isEmpty {
                        Button {
                            loaded = nil
                            self.target = target.deletingLastPathComponent()
                        } label: { Label("上一级", systemImage: "arrow.up") }
                        .disabled(busy)
                    }
                    if busy { ProgressView("正在读取文件夹…") }
                    if let message {
                        Text(message).foregroundStyle(.secondary)
                        Button("重试") { Task { await load() } }.disabled(busy)
                    }
                } header: { Text("当前位置") }
                if loaded != nil {
                    Section {
                        ForEach(folders) { folder in
                            Button {
                                loaded = nil
                                target = folder.url
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                    Text(folder.name)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                            }
                        }
                        if folders.isEmpty { Text("没有子文件夹").foregroundStyle(.secondary) }
                    } header: { Text("文件夹") }
                    .disabled(busy)
                    Section {
                        TextField("新文件夹名称", text: $newName)
                            .autocorrectionDisabled()
                        Button("新建并进入") { Task { await create() } }
                            .disabled(busy || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } footer: { Text("选择专用文件夹即可，同步文件会自动生成。") }
                    .disabled(busy)
                }
            }
            .navigationTitle("选择同步文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("选择此文件夹") {
                        guard let loaded else { return }
                        onSelect(loaded)
                        dismiss()
                    }.disabled(busy || loaded == nil)
                }
            }
            .task {
                do { target = try connection.folderURL() }
                catch { message = NASSyncError.invalidAddress.localizedDescription }
            }
            .task(id: target) { await load() }
        }
        .navigationViewStyle(.stack)
    }

    @MainActor private func load() async {
        guard let target else { return }
        busy = true
        loaded = nil
        message = nil
        defer { busy = false }
        let client = NASWebDAVClient(connection: connection)
        defer { client.close() }
        do {
            let result = try await client.listFolders(at: target)
            try Task.checkCancellation()
            folders = result
            loaded = target
        } catch is CancellationError {
            return
        } catch {
            message = (error as? NASSyncError)?.localizedDescription
                ?? "连接失败，请检查 WebDAV 地址、网络及 NAS 证书。"
        }
    }

    @MainActor private func create() async {
        guard let loaded else { return }
        busy = true
        message = nil
        let client = NASWebDAVClient(connection: connection)
        defer { client.close(); busy = false }
        do {
            let created = try await client.createFolder(named: newName, in: loaded)
            self.loaded = nil
            target = created
        } catch {
            message = (error as? NASSyncError)?.localizedDescription ?? "创建失败，请检查文件夹写入权限。"
        }
    }
}
