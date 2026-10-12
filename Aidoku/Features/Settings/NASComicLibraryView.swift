import AidokuRunner
import SwiftUI

struct NASComicLibraryView: View {
    var folder = ""
    @ObservedObject private var privacy = PrivacyDisplayStore.shared
    @ObservedObject private var manager = NASComicManager.shared
    @State private var entries: [NASComicEntry] = []
    @State private var loading = false
    @State private var refreshingLinks = false
    @State private var openingID: String?
    @State private var notice: String?
    @State private var message: String?
    @State private var query = ""
    @State private var showFolders = false
    @State private var pickerConnection: NASConnection?
    @State private var cacheConfirmation: NASComicEntry?
    @State private var reader: ReadingItem?
    @State private var loadID = UUID()
    private struct ReadingItem: Identifiable {
        let id = UUID()
        let manga: AidokuRunner.Manga
        let chapter: AidokuRunner.Chapter
    }
    private var interacting: Bool { manager.busy || loading || refreshingLinks || openingID != nil }
    private var visible: [NASComicEntry] { entries.filter { manager.isComicVisible(path: $0.path, isDirectory: $0.isDirectory) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        List {
            if folder.isEmpty {
                Section {
                    Text((try? manager.configuration().root.path) ?? "请先在 NAS 同步中保存连接")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        do {
                            let config = try manager.configuration()
                            // Start from the saved sync location so an absent default comics folder does not block browsing.
                            pickerConnection = config.connection
                            showFolders = true
                        } catch { message = NASConnection.message(for: error) }
                    } label: {
                        NASActionLabel(title: "选择漫画文件夹", systemImage: "folder")
                    }.disabled(interacting)
                    Button {
                        refreshingLinks = true
                        message = nil
                        notice = nil
                        Task {
                            defer { refreshingLinks = false }
                            do {
                                let count = try await manager.refreshUploadedLinks()
                                notice = "已关联 \(count) 个章节。原漫画选择“NAS 优先”后，仅已上传章节从 NAS 读取，其余章节仍使用原有下载或图源。"
                            } catch { message = NASConnection.message(for: error) }
                        }
                    } label: {
                        NASActionLabel(title: refreshingLinks ? "正在关联章节…" : "刷新已上传章节关联", systemImage: "link", busy: refreshingLinks)
                    }.disabled(interacting)
                    Button { Task { await manager.createLibrary(); await load() } } label: {
                        NASActionLabel(title: "准备默认漫画目录", systemImage: "folder.badge.plus", busy: manager.busy)
                    }.disabled(interacting)
                } header: { Text("NAS 漫画库") } footer: {
                    Text("沿用 NAS 同步的连接及备用地址。可选已有 CBZ / ZIP 文件夹；上传入口在“下载 → 漫画 → 菜单”。默认目录为同步文件夹下的 AidokuT-Comics。")
                }
            }
            Section {
                Text(manager.status).font(.footnote).foregroundStyle(.secondary)
                if manager.busy {
                    if let progress = manager.progress { ProgressView(value: progress) } else { ProgressView() }
                    Button("取消传输", role: .cancel) { manager.cancel() }
                }
                NavigationLink("管理手机章节缓存") { NASComicCacheView() }
                Text("阅读缓存 " + ByteCountFormatter.string(fromByteCount: manager.cacheBytes, countStyle: .file) + " / 2 GB")
                    .font(.footnote).foregroundStyle(.secondary)
            } footer: {
                Text("点开即按页在线读取，不预先下载整章。长按章节可选“缓存整章”用于离线阅读；左滑可移除手机缓存，不删除 NAS 原文件。上传时保持 App 在前台。")
            }
            NASConnectionStatusSection()
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary) }
            }
            if let message {
                Section {
                    Label(message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary)
                    Button("重新读取目录") { Task { await load() } }.disabled(interacting)
                }
            }
            Section {
                if loading { ProgressView("正在读取目录…") }
                ForEach(visible) { entry in
                    if entry.isDirectory {
                        NavigationLink(destination: NASComicLibraryView(folder: entry.path)) {
                            Label(entry.name, systemImage: "folder")
                        }.disabled(interacting)
                    } else {
                        Button { Task { await open(entry) } } label: {
                            HStack(spacing: 12) {
                                if openingID == entry.path {
                                    ProgressView()
                                } else {
                                    Image(systemName: manager.isCached(entry) ? "checkmark.circle" : "book.closed")
                                        .foregroundStyle(.tint)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text((entry.name as NSString).deletingPathExtension).foregroundStyle(.primary).lineLimit(2)
                                    Text(openingID == entry.path ? "正在打开章节…" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file) + (manager.isCached(entry) ? " · 已缓存" : " · NAS"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(interacting)
                        .contextMenu {
                            Button("缓存整章，供离线阅读") { Task { await cache(entry) } }.disabled(interacting)
                        }
                        .swipeActions {
                            if manager.isCached(entry) {
                                Button("移除缓存", role: .destructive) {
                                    do { try manager.removeCache(entry) } catch { message = NASConnection.message(for: error) }
                                }.disabled(manager.busy)
                            }
                        }
                    }
                }
                if !loading && visible.isEmpty && message == nil { Text("此处没有 CBZ / ZIP 漫画或子文件夹").foregroundStyle(.secondary) }
            } header: { Text("文件夹与章节") }
        }
        .buttonStyle(NASActionButtonStyle())
        .navigationTitle(folder.isEmpty ? "NAS 漫画库" : (folder as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索当前目录")
        .refreshable { await load() }
        .task { await manager.enableSource(); manager.refreshCacheSize(); await load() }
        .sheet(isPresented: $showFolders) {
            if let connection = pickerConnection {
                NASFolderPicker(connection: connection, title: "选择漫画文件夹") { url in
                    do { try manager.selectFolder(url); Task { await load() } }
                    catch { message = NASConnection.message(for: error) }
                }
            }
        }
        .alert("此章节需要整章缓存", isPresented: Binding(get: { cacheConfirmation != nil }, set: { if !$0 { cacheConfirmation = nil } })) {
            Button("缓存整章后阅读") {
                if let entry = cacheConfirmation { Task { if await cache(entry) { await open(entry) } } }
                cacheConfirmation = nil
            }
            Button("取消", role: .cancel) { cacheConfirmation = nil }
        } message: { Text("此 NAS 不支持 Range 分段读取，或压缩格式不支持在线解码。只有确认后才下载整章。") }
        .fullScreenCover(item: $reader) { item in
            SwiftUIReaderNavigationController(source: SourceManager.shared.store.source(for: NASSourceRunner.sourceKey), manga: item.manga, chapter: item.chapter)
                .ignoresSafeArea()
        }
    }
    @MainActor private func load() async {
        let id = UUID(); loadID = id; loading = true; message = nil
        defer { if loadID == id { loading = false } }
        do {
            let result = try await manager.entries(folder)
            guard loadID == id, !Task.isCancelled else { return }
            entries = result
        } catch {
            guard loadID == id, !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
            message = NASConnection.message(for: error)
        }
    }
    @MainActor private func open(_ entry: NASComicEntry) async {
        guard openingID == nil else { return }
        openingID = entry.path
        defer { openingID = nil }
        message = nil
        do {
            _ = try await manager.onlinePages(entry)
            let manga = try manager.manga(folder: folder, entries: entries)
            let key = NASComicPaths.key(entry.path, fingerprint: try manager.configuration().fingerprint)
            guard let chapter = manga.chapters?.first(where: { $0.key == key }) else { throw NASComicError.invalidArchive }
            reader = .init(manga: manga, chapter: chapter)
        } catch NASComicError.requiresWholeArchive { cacheConfirmation = entry }
        catch { message = NASConnection.message(for: error) }
    }
    @discardableResult @MainActor private func cache(_ entry: NASComicEntry) async -> Bool {
        do { _ = try await manager.cachedArchive(entry); return true }
        catch { message = NASConnection.message(for: error); return false }
    }
}

struct NASComicUploadView: View {
    let manga: DownloadedMangaInfo
    let chapters: [DownloadedChapterInfo]
    @ObservedObject private var manager = NASComicManager.shared
    @Environment(\.dismiss) private var dismiss

    private var uploadSummary: NASComicUploadSummary? {
        guard let summary = manager.lastUpload,
              summary.sourceID == manga.sourceId,
              summary.mangaID == manga.mangaId,
              let config = try? manager.configuration(),
              summary.fingerprint == config.fingerprint else { return nil }
        return summary
    }

    private func uploadStateTitle(_ summary: NASComicUploadSummary) -> String {
        switch summary.state {
        case .uploading: "正在上传"
        case .completed: "本次上传已完成"
        case .cancelled: "本次上传已取消"
        case .failed: "本次上传未完成"
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(manga.displayTitle).font(.headline)
                    Text("本次上传 \(chapters.filter { !$0.failed }.count) 个完整章节")
                    Text((try? manager.configuration().root.path) ?? "请先在 NAS 同步中配置并保存连接")
                        .font(.footnote).foregroundStyle(.secondary)
                } footer: { Text("以 CBZ 保存到 NAS，手机原下载保留。同名章节会跳过，断网后可重试。上传一章只保存这一章，不会自动下载其余章节。") }
                Section {
                    Text(manager.status).font(.footnote)
                    if manager.busy {
                        if let progress = manager.progress { ProgressView(value: progress) } else { ProgressView() }
                        Button("取消上传", role: .cancel) { manager.cancel() }
                    } else {
                        Button { manager.upload(manga: manga, chapters: chapters) } label: {
                            NASActionLabel(title: "开始上传", systemImage: "arrow.up.doc")
                        }
                        .disabled((try? manager.configuration()) == nil || chapters.allSatisfy(\.failed))
                    }
                }
                if let summary = uploadSummary {
                    Section {
                        Text(uploadStateTitle(summary)).font(.headline)
                        HStack { Text("新上传"); Spacer(); Text("\(summary.uploaded) / \(summary.total) 章") }
                        HStack { Text("NAS 已存在，跳过上传"); Spacer(); Text("\(summary.skipped) 章") }
                        HStack { Text("已关联原漫画"); Spacer(); Text("\(summary.linked) 章") }
                        if let error = summary.error {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if summary.uploaded + summary.skipped > 0 {
                            NavigationLink { NASComicLibraryView(folder: summary.folder) } label: {
                                Label("查看本次上传的章节", systemImage: "books.vertical")
                            }
                        }
                    } header: { Text("上传结果") } footer: {
                        Text("手机原下载仍保留。已关联的章节可以从原漫画切换为“NAS 优先”；未上传或未关联的章节仍按原方式阅读。")
                    }
                }
                Section {
                    NavigationLink { NASComicLibraryView() } label: {
                        Label("打开 NAS 漫画库", systemImage: "externaldrive.fill")
                    }
                } header: { Text("上传后怎么阅读") } footer: {
                    Text("在 NAS 漫画库打开漫画文件夹，再点章节在线阅读；也可回到原漫画阅读页，在阅读设置的“读取来源”选择“NAS 优先”。只有已上传并关联的章节走 NAS，其他章节仍使用原有下载或图源。")
                }
            }
            .buttonStyle(NASActionButtonStyle())
            .navigationTitle("上传到 NAS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .navigationViewStyle(.stack)
    }
}

private struct NASComicCacheView: View {
    @ObservedObject private var manager = NASComicManager.shared
    @State private var items: [NASComicManager.CacheItem] = []
    @State private var message: String?
    var body: some View {
        List {
            if let message { Text(message).foregroundStyle(.secondary) }
            Section {
                ForEach(items) { item in
                    HStack {
                        Text(item.name).lineLimit(2)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    }.swipeActions {
                        Button("移除缓存", role: .destructive) {
                            do { try manager.removeCacheFile(item.id); items = manager.cacheItems() }
                            catch { message = NASConnection.message(for: error) }
                        }.disabled(manager.busy)
                    }
                }
                if items.isEmpty { Text("没有整章缓存").foregroundStyle(.secondary) }
            } footer: { Text("左滑移除单章手机缓存。NAS 上的原文件保持不变，下次仍可按页在线阅读。") }
        }
        .navigationTitle("章节缓存")
        .task { items = manager.cacheItems() }
        .onReceive(NotificationCenter.default.publisher(for: .privacyDisplayChanged)) { _ in items = manager.cacheItems() }
    }
}
