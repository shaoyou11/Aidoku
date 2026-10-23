import AidokuRunner
import SwiftUI

struct NASComicLibraryView: View {
    var folder = ""
    @Environment(\.dismiss) private var dismiss
    @State private var showManagement = false
    @State private var trashConfirmation: String?
    @ObservedObject private var privacy = PrivacyDisplayStore.shared
    @ObservedObject private var manager = NASComicManager.shared
    @State private var entries: [NASComicEntry] = []
    @State private var loading = false
    @State private var refreshingLinks = false
    @State private var openingID: String?
    @State private var notice: String?
    @State private var message: String?
    @State private var query = ""
    @State private var folderSelection: FolderSelection?
    private struct FolderSelection: Identifiable {
        let id = UUID()
        let connection: NASConnection
    }
    @State private var cacheConfirmation: NASComicEntry?
    @State private var deleteConfirmation: NASComicEntry?
    @State private var reader: ReadingItem?
    @State private var loadID = UUID()
    @State private var book: AidokuRunner.Manga?
    @State private var previews: [String: AidokuRunner.Manga] = [:]
    @State private var loadingDetails = false
    @State private var readingStates: [String: NASComicManager.ReadingState] = [:]
    @State private var cachedFolders: Set<String> = []
    @State private var children: [String: [NASComicEntry]] = [:]
    @State private var loadedFingerprint: String?
    @State private var filter: ReadingFilter = .all
    @State private var removeCacheConfirmation: NASComicEntry?
    private enum ReadingFilter: String, CaseIterable { case all = "全部", recent = "最近阅读", unread = "未读", cached = "已缓存" }
    private var continuation: NASComicManager.ReadingState? {
        readingStates.values.filter {
            !$0.completed && $0.page > 0 && manager.isComicVisible(path: $0.path, isDirectory: false)
                && (folder.isEmpty || ($0.path as NSString).deletingLastPathComponent == folder)
        }.max { $0.date < $1.date }
    }
    private func matchesFilter(_ entry: NASComicEntry) -> Bool {
        switch filter {
        case .all: return true
        case .cached: return entry.isDirectory ? cachedFolders.contains(where: { $0 == entry.path || $0.hasPrefix(entry.path + "/") }) : manager.isCached(entry)
        case .recent: return entry.isDirectory ? readingStates.keys.contains { $0.hasPrefix(entry.path + "/") } : readingStates[entry.path] != nil
        case .unread:
            if entry.isDirectory {
                let chapters = children[entry.path]?.filter { !$0.isDirectory } ?? []
                return chapters.isEmpty || chapters.contains { readingStates[$0.path]?.completed != true }
            }
            return readingStates[entry.path]?.completed != true
        }
    }
    private struct ReadingItem: Identifiable {
        let id = UUID()
        let manga: AidokuRunner.Manga
        let chapter: AidokuRunner.Chapter
        let startPage: Int?
    }
    private var interacting: Bool { manager.busy || loading || refreshingLinks || openingID != nil }
    private var visible: [NASComicEntry] {
        guard book.map({ privacy.allows($0) }) != false else { return [] }
        return entries.filter {
            manager.isComicVisible(path: $0.path, isDirectory: $0.isDirectory)
                && previews[$0.path].map({ privacy.allows($0) }) != false
                && matchesFilter($0)
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || previews[$0.path]?.title.localizedCaseInsensitiveContains(query) == true)
        }.sorted { left, right in
            guard filter == .recent else { return false }
            func date(_ entry: NASComicEntry) -> Date {
                if !entry.isDirectory { return readingStates[entry.path]?.date ?? .distantPast }
                return readingStates.values.filter { $0.path.hasPrefix(entry.path + "/") }.map(\.date).max() ?? .distantPast
            }
            return date(left) > date(right)
        }
    }
    var body: some View {
        List {
            if let recent = continuation {
                Section {
                    Button { Task { await continueReading(recent) } } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("继续阅读", systemImage: "book.fill").font(.headline)
                            Text((recent.path as NSString).lastPathComponent).lineLimit(2).foregroundStyle(.primary)
                            Text(recent.label + " · " + ((recent.path as NSString).deletingLastPathComponent)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }.disabled(interacting)
                }
            }
            NASConnectionStatusSection(compact: true)
            if manager.cachedListingPaths.contains(folder) {
                Section {
                    Label("网络读取失败，显示上次目录；手机缓存仍可阅读。", systemImage: "exclamationmark.circle").font(.footnote)
                    Button("重新读取目录") { Task { await load() } }.disabled(interacting)
                }
            }
            if manager.busy {
                Section {
                    Text(manager.status).font(.footnote)
                    if let progress = manager.progress { ProgressView(value: progress) } else { ProgressView() }
                    Button("取消传输", role: .cancel) { manager.cancel() }
                }
            }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary) }
            }
            if let message {
                Section {
                    Label(message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary)
                    Button("重新读取目录") { Task { await load() } }.disabled(interacting)
                }
            }
            if let book, privacy.allows(book) {
                Section {
                    bookHeader(book, expanded: true)
                } header: { Text("漫画详情") }
            }
            Section {
                Picker("筛选", selection: $filter) {
                    ForEach(ReadingFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
            }
            Section {
                if loading { ProgressView("正在读取目录…") }
                if loadingDetails { ProgressView("正在读取封面与详情…").font(.footnote) }
                ForEach(visible) { entry in
                    if entry.isDirectory {
                        NavigationLink(destination: NASComicLibraryView(folder: entry.path)) {
                            if let preview = previews[entry.path] {
                                bookHeader(preview, expanded: false)
                            } else {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder")
                                        .font(.title2).foregroundStyle(.secondary)
                                        .frame(width: 56, height: 84)
                                    Text(entry.name).font(.headline).lineLimit(3)
                                }.padding(.vertical, 4)
                            }
                        }.disabled(interacting)
                        .task(id: loadID) { await loadPreview(entry) }
                        .contextMenu {
                            Button("移到 NAS 回收站", role: .destructive) { trashConfirmation = entry.path }.disabled(interacting)
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button("移到 NAS 回收站", role: .destructive) { trashConfirmation = entry.path }.disabled(interacting)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Button { Task { await open(entry) } } label: {
                                HStack(spacing: 12) {
                                    if openingID == entry.path {
                                        ProgressView()
                                    } else {
                                        Image(systemName: manager.isCached(entry) ? "checkmark.circle" : "book.closed")
                                            .foregroundStyle(.tint)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(chapterTitle(entry)).foregroundStyle(.primary).lineLimit(2)
                                        Text(openingID == entry.path ? "正在打开章节…" : (readingStates[entry.path]?.label ?? "未读") + " · " + (manager.isCached(entry) ? "手机缓存" : "NAS 在线") + " · " + ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(minHeight: 44, alignment: .leading)
                            }
                            .disabled(interacting)
                        }
                        .contextMenu {
                            Button("缓存整章，供离线阅读") { Task { await cache(entry) } }.disabled(interacting)
                            Button("删除 NAS 章节", role: .destructive) { deleteConfirmation = entry }.disabled(interacting)
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button("删除 NAS 章节", role: .destructive) { deleteConfirmation = entry }.disabled(interacting)
                            if manager.isCached(entry) {
                                Button("移除缓存", role: .destructive) {
                                    removeCacheConfirmation = entry
                                }.disabled(manager.busy)
                            }
                        }
                    }
                }
                if !loading && visible.isEmpty && message == nil { Text(filter == .all && query.isEmpty ? "此处没有 CBZ / ZIP 漫画或子文件夹" : "没有符合筛选条件的漫画或章节").foregroundStyle(.secondary) }
            } header: { Text("文件夹与章节") } footer: { Text("此页内容来自 NAS；已缓存章节优先读取手机。原图源漫画可从书架阅读，并在阅读设置中选择来源。") }
        }
        .buttonStyle(NASActionButtonStyle())
        .navigationTitle(folder.isEmpty ? "NAS 漫画库" : (folder as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索当前目录")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showManagement = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("漫画库管理")
            }
        }
        .sheet(isPresented: $showManagement) {
            NavigationView {
                Form {
                    Section {
                        Text((try? manager.configuration().root.path) ?? "请先在 NAS 同步中保存连接")
                            .font(.footnote).foregroundStyle(.secondary).privacySensitive()
                        Button {
                            do {
                                let config = try manager.configuration()
                                // Start from the saved sync location so an absent default comics folder does not block browsing.
                                folderSelection = FolderSelection(connection: config.connection)
                            } catch { message = NASConnection.message(for: error) }
                        } label: {
                            NASActionLabel(title: "选择漫画文件夹", systemImage: "folder")
                        }.disabled(interacting || !folder.isEmpty)
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
                        NavigationLink("管理手机章节缓存") { NASComicCacheView() }
                        NavigationLink("NAS 连接设置") { NASSyncView() }
                        Text("阅读缓存 " + ByteCountFormatter.string(fromByteCount: manager.cacheBytes, countStyle: .binary) + " / " + ByteCountFormatter.string(fromByteCount: manager.cacheLimit, countStyle: .binary))
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("沿用 NAS 同步的连接及备用地址。可选已有 CBZ / ZIP 文件夹；上传入口在“下载 → 漫画 → 菜单”。默认目录为同步文件夹下的 AidokuT-Comics。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !folder.isEmpty {
                        Section {
                            Button("整本移到 NAS 回收站", role: .destructive) { showManagement = false; trashConfirmation = folder }.disabled(interacting)
                        } footer: { Text("包含当前文件夹的所有章节，不会删除手机书架和原图源漫画。") }
                    }
                }
                .navigationTitle("漫画库管理").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showManagement = false } } }
                .sheet(item: $folderSelection) { selection in
                    NASFolderPicker(connection: selection.connection, title: "选择漫画文件夹") { url in
                        do { try manager.selectFolder(url); Task { await load() } }
                        catch { message = NASConnection.message(for: error) }
                    }
                }
            }.navigationViewStyle(.stack)
        }
        .refreshable { await load() }
        .onChange(of: manager.cacheBytes) { _ in cachedFolders = Set(manager.cacheItems().map(\.manga)) }
        .onReceive(NotificationCenter.default.publisher(for: .privacyDisplayChanged)) { _ in cachedFolders = Set(manager.cacheItems().map(\.manga)) }
        .task {
            showManagement = (try? manager.configuration()) == nil
            await manager.enableSource()
            manager.refreshCacheSize()
            await load()
        }
        .alert("此章节需要整章缓存", isPresented: Binding(get: { cacheConfirmation != nil }, set: { if !$0 { cacheConfirmation = nil } })) {
            Button("缓存整章后阅读") {
                if let entry = cacheConfirmation { Task { if await cache(entry) { await open(entry) } } }
                cacheConfirmation = nil
            }
            Button("取消", role: .cancel) { cacheConfirmation = nil }
        } message: { Text("此 NAS 不支持 Range 分段读取，或压缩格式不支持在线解码。只有确认后才下载整章。") }
        .alert("移到 NAS 回收站？", isPresented: Binding(get: { trashConfirmation != nil }, set: { if !$0 { trashConfirmation = nil } })) {
            Button("移到回收站", role: .destructive) {
                if let target = trashConfirmation {
                    Task {
                        do {
                            try await manager.trashManga(folder: target)
                            if target == folder { dismiss() } else { await load() }
                        } catch { message = NASConnection.message(for: error) }
                    }
                }
                trashConfirmation = nil
            }
            Button("取消", role: .cancel) { trashConfirmation = nil }
        } message: {
            Text("将“\(((trashConfirmation ?? "") as NSString).lastPathComponent)”及其章节移出漫画库。文件保留在 NAS 的 .aidokut-trash 目录，仍占用空间；可在 NAS 文件管理器中恢复或永久删除。")
        }
        .alert("删除 NAS 章节？", isPresented: Binding(get: { deleteConfirmation != nil }, set: { if !$0 { deleteConfirmation = nil } })) {
            Button("删除此章", role: .destructive) {
                if let entry = deleteConfirmation {
                    Task {
                        do { try await manager.deleteChapter(entry); await load() }
                        catch { message = NASConnection.message(for: error) }
                    }
                }
                deleteConfirmation = nil
            }
            Button("取消", role: .cancel) { deleteConfirmation = nil }
        } message: {
            Text("仅删除 NAS 上的“\(deleteConfirmation?.name ?? "")”。若手机原下载也已删除，需要从原图源重新下载才能恢复。")
        }
        .alert("移除手机缓存？", isPresented: Binding(get: { removeCacheConfirmation != nil }, set: { if !$0 { removeCacheConfirmation = nil } })) {
            Button("移除此章缓存", role: .destructive) {
                if let entry = removeCacheConfirmation {
                    do { try manager.removeCache(entry) } catch { message = NASConnection.message(for: error) }
                }
                removeCacheConfirmation = nil
            }
            Button("取消", role: .cancel) { removeCacheConfirmation = nil }
        } message: { Text("仅移除“\(removeCacheConfirmation?.name ?? "")”的手机缓存。其他离线章节和 NAS 原文件保留。") }
        .fullScreenCover(item: $reader, onDismiss: { Task { readingStates = await manager.readingStates() } }) { item in
            SwiftUIReaderNavigationController(source: SourceManager.shared.store.source(for: NASSourceRunner.sourceKey), manga: item.manga, chapter: item.chapter, startPage: item.startPage)
                .ignoresSafeArea()
        }
    }
    private func chapterTitle(_ entry: NASComicEntry) -> String {
        guard let fingerprint = try? manager.configuration().fingerprint else { return entry.name }
        return book?.chapters?.first(where: { $0.key == NASComicPaths.key(entry.path, fingerprint: fingerprint) })?.title
            ?? (entry.name as NSString).deletingPathExtension
    }
    @ViewBuilder private func bookHeader(_ manga: AidokuRunner.Manga, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                MangaCoverView(source: nil, coverImage: manga.cover ?? "", width: expanded ? 88 : 56, height: expanded ? 132 : 84)
                VStack(alignment: .leading, spacing: 6) {
                    Text(manga.title).font(.headline).foregroundStyle(.primary).lineLimit(3)
                    if let authors = manga.authors, !authors.isEmpty {
                        Text(authors.joined(separator: "、")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("NAS · \(manga.chapters?.count ?? 0) 章").font(.caption).foregroundStyle(.secondary)
                }
            }
            if expanded, let description = manga.description, !description.isEmpty {
                Text(description).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(.vertical, 4)
    }
    @MainActor private func load() async {
        let id = UUID(); loadID = id; loading = true; message = nil
        defer { if loadID == id { loading = false } }
        do {
            let fingerprint = try manager.configuration().fingerprint
            if loadedFingerprint != fingerprint {
                loadedFingerprint = fingerprint; previews = [:]; children = [:]; entries = []; book = nil; readingStates = [:]
            }
            let result = try await manager.entries(folder)
            guard loadID == id, !Task.isCancelled else { return }
            entries = result
            readingStates = await manager.readingStates()
            cachedFolders = Set(manager.cacheItems().map(\.manga))
            guard loadID == id, !Task.isCancelled else { return }
            loading = false
            loadingDetails = true
            defer { if loadID == id { loadingDetails = false } }
            if result.contains(where: { !$0.isDirectory }) {
                let details = try await manager.detailedManga(folder: folder, entries: result)
                guard loadID == id, !Task.isCancelled else { return }
                book = details
            } else { book = nil }
        } catch {
            guard loadID == id, !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
            message = NASConnection.message(for: error)
        }
    }
    @MainActor private func loadPreview(_ entry: NASComicEntry) async {
        let id = loadID
        do {
            let children = try await manager.entries(entry.path, refresh: false)
            guard loadID == id, !Task.isCancelled else { return }
            self.children[entry.path] = children
            let details = try await manager.detailedManga(folder: entry.path, entries: children, allChapters: false)
            guard loadID == id, !Task.isCancelled else { return }
            previews[entry.path] = details
        } catch {
            // A cover failure must not block opening the directory itself.
        }
    }
    @MainActor private func open(_ entry: NASComicEntry) async {
        guard openingID == nil else { return }
        openingID = entry.path
        defer { openingID = nil }
        message = nil
        do {
            _ = try await manager.onlinePages(entry)
            let parent = (entry.path as NSString).deletingLastPathComponent
            let manga: AidokuRunner.Manga
            if parent == folder { manga = try book ?? manager.manga(folder: folder, entries: entries) }
            else {
                let siblings = try await manager.entries(parent, refresh: false)
                manga = try await manager.detailedManga(folder: parent, entries: siblings, allChapters: false)
            }
            guard privacy.allows(manga) else { return }
            let key = NASComicPaths.key(entry.path, fingerprint: try manager.configuration().fingerprint)
            guard let chapter = manga.chapters?.first(where: { $0.key == key }) else { throw NASComicError.invalidArchive }
            let saved = readingStates[entry.path]
            reader = .init(manga: manga, chapter: chapter, startPage: saved.flatMap { !$0.completed && $0.page > 0 ? $0.page : nil })
        } catch NASComicError.requiresWholeArchive { cacheConfirmation = entry }
        catch { message = NASConnection.message(for: error) }
    }
    @MainActor private func continueReading(_ state: NASComicManager.ReadingState) async {
        do {
            let siblings = try await manager.entries((state.path as NSString).deletingLastPathComponent, refresh: false)
            guard let entry = siblings.first(where: { $0.path == state.path && !$0.isDirectory }) else {
                message = "该章节已移动或删除，请刷新目录。"; return
            }
            await open(entry)
        } catch { message = NASConnection.message(for: error) }
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
    @State private var removeLocal = true

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
                    Toggle("校验成功后删除手机下载", isOn: $removeLocal).disabled(manager.busy)
                } footer: { Text("迁移为 NAS 上的 CBZ 章节，校验文件、图片及阅读关联后再清理手机原下载。校验失败会保留原下载；关闭开关则仅复制。只处理本次选择的章节。") }
                Section {
                    Text(manager.status).font(.footnote)
                    if manager.busy {
                        if let progress = manager.progress { ProgressView(value: progress) } else { ProgressView() }
                        Button("取消上传", role: .cancel) { manager.cancel() }
                    } else {
                        Button { manager.upload(manga: manga, chapters: chapters, removeLocal: removeLocal) } label: {
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
                        HStack { Text("已清理手机下载"); Spacer(); Text("\(summary.removedLocal ?? 0) 章") }
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
                        Text("每个 CBZ 对应一个已下载章节，章内包含多张漫画图片。已关联章节可从原漫画以“NAS 优先”阅读；其余章节仍按原方式读取。")
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

struct NASComicLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            NASComicLibraryView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }.navigationViewStyle(.stack)
    }
}
