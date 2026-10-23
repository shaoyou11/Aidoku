import SwiftUI

struct NASComicCacheView: View {
    @ObservedObject private var manager = NASComicManager.shared
    @State private var items: [NASComicManager.CacheItem] = []
    @State private var selection: Set<URL> = []
    @State private var message: String?
    @State private var preview = false
    @State private var confirmation = false
    @State private var removing = false
    private var groups: [String] { Set(items.map(\.manga)).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    private var selected: [NASComicManager.CacheItem] { items.filter { selection.contains($0.id) } }
    private var retained: [NASComicManager.CacheItem] { items.filter { !selection.contains($0.id) } }
    private var reclaimable: Int64 { selected.reduce(0) { $0 + $1.size } }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary) }
    var body: some View {
        List {
            Section {
                Picker("缓存容量", selection: Binding(get: { Int(manager.cacheLimit / 1024 / 1024) }, set: { manager.setCacheLimit($0) })) {
                    ForEach(NASComicCachePolicy.capacitiesMB, id: \.self) { mb in
                        Text(mb < 1024 ? "\(mb) MB" : "\(mb / 1024) GB").tag(mb)
                    }
                }.disabled(manager.busy || removing)
                Text("已使用 \(size(manager.cacheBytes)) / \(size(manager.cacheLimit))")
                if manager.cacheBytes > manager.cacheLimit {
                    Label("现有离线章已超过所选容量；清理前暂停新增缓存。", systemImage: "exclamationmark.circle").font(.footnote)
                }
            } footer: { Text("最高固定 2 GB。降低容量不会自动删除已有离线章节。此处仅管理 NAS 整章缓存，原图源下载保持不变。") }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
            ForEach(groups, id: \.self) { group in
                Section {
                    let chapters = items.filter { $0.manga == group }
                    Button(selection.isSuperset(of: chapters.map(\.id)) ? "取消选择这本漫画" : "选择这本漫画的缓存") {
                        if selection.isSuperset(of: chapters.map(\.id)) { selection.subtract(chapters.map(\.id)) }
                        else { selection.formUnion(chapters.map(\.id)) }
                    }.disabled(manager.busy || removing)
                    ForEach(chapters) { item in
                        Button {
                            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name).foregroundStyle(.primary)
                                    Text(size(item.size)).font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(minHeight: 44)
                        }.disabled(manager.busy || removing)
                    }
                } header: { Text(group) }
            }
            if items.isEmpty { Text(manager.cacheBytes > 0 ? "没有可显示的章节缓存。隐私模式隐藏的章节或其他漫画库缓存继续保留。" : "没有整章缓存").foregroundStyle(.secondary) }
            if !items.isEmpty {
                Section {
                    Text("本次可清理 \(size(reclaimable)) · 保留 \(retained.count) 个离线章节")
                    Button("查看清理明细") { preview = true }.disabled(selected.isEmpty || manager.busy || removing)
                } footer: { Text("先选择要移除的章节，再核对明细。未选择的离线章、隐私模式隐藏的章节及 NAS 原文件均保留。") }
            }
        }
        .navigationTitle("手机章节缓存")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .privacyDisplayChanged)) { _ in preview = false; confirmation = false; selection = []; reload() }
        .sheet(isPresented: $preview) {
            NavigationView {
                List {
                    Section { Text("可清理 \(size(reclaimable))，保留 \(retained.count) 章。NAS 原文件与原图源下载不受影响。") }
                    Section("将移除的手机缓存（\(selected.count) 章）") {
                        ForEach(selected) { item in Text(item.manga + " · " + item.name) }
                    }
                    Section("保留的离线章节（\(retained.count) 章）") {
                        ForEach(retained) { item in Text(item.manga + " · " + item.name) }
                        if retained.isEmpty { Text("本页没有其他可见缓存；隐私模式隐藏的章节仍保留。").foregroundStyle(.secondary) }
                    }
                    Section {
                        Button("确认移除所选缓存", role: .destructive) { confirmation = true }
                            .disabled(manager.busy || removing || selected.isEmpty)
                    }
                }
                .navigationTitle("清理确认")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { preview = false }.disabled(removing) } }
                .confirmationDialog("移除 \(selected.count) 章手机缓存？", isPresented: $confirmation, titleVisibility: .visible) {
                    Button("移除缓存", role: .destructive) { removeSelected() }
                } message: { Text("移除后需连接 NAS 才能重新阅读这些章节。未选择的章节继续保留。") }
            }.navigationViewStyle(.stack).interactiveDismissDisabled(removing)
        }
    }
    private func reload() {
        manager.refreshCacheSize()
        items = manager.cacheItems()
        selection.formIntersection(Set(items.map(\.id)))
    }
    private func removeSelected() {
        guard !manager.busy, !removing else { return }
        removing = true
        let targets = selected
        var removed = 0
        var failure: String?
        // Each confirmed file is checked and removed individually; never remove a cache directory.
        for item in targets {
            do { try manager.removeCacheFile(item.id); removed += 1 }
            catch { failure = NASConnection.message(for: error); break }
        }
        message = "已移除 \(removed) 章缓存。" + (failure.map { "其余保留：" + $0 } ?? "未选择的离线章节已保留。")
        selection = []; preview = false; removing = false; reload()
    }
}
