import SwiftUI

/// 阅读页：按版心分页，横向翻页，保存进度与书签。
struct ReaderView: View {
    let book: Book
    @EnvironmentObject private var store: BookStore
    @Environment(\.dismiss) private var dismiss

    @State private var fullText: String = ""
    @State private var pages: [Paginator.Page] = []
    @State private var pageIndex: Int = 0
    @State private var fontSize: CGFloat = 18
    @State private var lineSpacing: CGFloat = 6
    @State private var showTOC = false
    @State private var showBookmarks = false
    @State private var showSettings = false
    @State private var loadFailed = false
    @State private var current: Book

    init(book: Book) {
        self.book = book
        _current = State(initialValue: book)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let size = CGSize(width: max(1, geo.size.width - 32), height: max(1, geo.size.height - 32))
                Group {
                    if loadFailed {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                            Text("文件已丢失或无法读取").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if pages.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TabView(selection: $pageIndex) {
                            ForEach(Array(pages.enumerated()), id: \.offset) { idx, page in
                                ScrollView {
                                    Text(Paginator.text(fullText, page: page))
                                        .font(.system(size: fontSize))
                                        .lineSpacing(lineSpacing)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 16)
                                        .textSelection(.enabled)
                                }
                                .tag(idx)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .onChange(of: pageIndex) { _, _ in saveProgress() }
                    }
                }
                .onAppear { prepare(size: size) }
                .onChange(of: size) { _, newValue in repaginate(size: newValue) }
                .onChange(of: fontSize) { _, _ in repaginate(size: size) }
                .onChange(of: lineSpacing) { _, _ in repaginate(size: size) }
            }
            .navigationTitle(current.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { saveProgress(); dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showTOC = true } label: { Image(systemName: "list.bullet") }
                    Button { showBookmarks = true } label: { Image(systemName: "bookmark") }
                    Button { showSettings = true } label: { Image(systemName: "textformat.size") }
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Text(pages.isEmpty ? "" : "\(min(pageIndex + 1, pages.count)) / \(pages.count)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .sheet(isPresented: $showTOC) {
                List(current.chapters.isEmpty ? [Chapter(title: "（无章节）", location: 0)] : current.chapters) { ch in
                    Button {
                        jump(toOffset: ch.location)
                        showTOC = false
                    } label: {
                        Text(ch.title)
                    }
                }
                .navigationTitle("目录")
            }
            .sheet(isPresented: $showBookmarks) {
                BookmarksSheet(book: $current, onJump: { off in
                    jump(toOffset: off)
                    showBookmarks = false
                }, onAdd: addBookmark, onDelete: deleteBookmark)
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet(fontSize: $fontSize, lineSpacing: $lineSpacing)
            }
        }
    }

    // MARK: - 载入与分页

    private func prepare(size: CGSize) {
        guard fullText.isEmpty else { repaginate(size: size); return }
        guard let text = store.text(for: current) else {
            loadFailed = true
            return
        }
        fullText = text
        if let saved = BookCache.loadProgress(bookID: current.id) {
            current.lastOffset = saved.offset
            current.lastChapterIndex = saved.chapter
        }
        repaginate(size: size)
    }

    private func repaginate(size: CGSize) {
        guard !fullText.isEmpty, size.width > 1, size.height > 1 else { return }
        if let cached = BookCache.loadPages(bookID: current.id, fontSize: fontSize,
                                           lineSpacing: lineSpacing, size: size), !cached.isEmpty {
            pages = cached
        } else {
            let computed = Paginator.paginate(fullText, size: size, fontSize: fontSize, lineSpacing: lineSpacing)
            pages = computed
            BookCache.storePages(computed, bookID: current.id, fontSize: fontSize,
                                 lineSpacing: lineSpacing, size: size)
        }
        pageIndex = Paginator.pageIndex(forOffset: current.lastOffset, in: pages)
    }

    private func jump(toOffset offset: Int) {
        guard !pages.isEmpty else { return }
        let idx = Paginator.pageIndex(forOffset: max(0, offset), in: pages)
        pageIndex = min(max(0, idx), pages.count - 1)
        saveProgress()
    }

    // MARK: - 进度与书签

    private var currentOffset: Int {
        guard pageIndex >= 0, pageIndex < pages.count else { return 0 }
        return pages[pageIndex].offset
    }

    private func saveProgress() {
        let off = currentOffset
        let chapter = chapterIndex(forOffset: off)
        current.lastOffset = off
        current.lastChapterIndex = chapter
        BookCache.storeProgress(bookID: current.id, offset: off, chapter: chapter)
        store.updateProgress(bookID: current.id, offset: off, chapter: chapter)
    }

    private func chapterIndex(forOffset offset: Int) -> Int {
        guard !current.chapters.isEmpty else { return 0 }
        var idx = 0
        for (i, ch) in current.chapters.enumerated() where ch.location <= offset { idx = i }
        return idx
    }

    private func currentSnippet() -> String {
        let page = pages[safe: pageIndex]
        guard let page else { return "" }
        let text = Paginator.text(fullText, page: page).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(40))
    }

    private func addBookmark() {
        let bm = Bookmark(bookID: current.id, snippet: currentSnippet(), offset: currentOffset, length: 0, createdAt: Date())
        current.bookmarks.append(bm)
        store.updateBookmarkList(bookID: current.id, bookmarks: current.bookmarks)
    }

    private func deleteBookmark(_ id: UUID) {
        current.bookmarks.removeAll { $0.id == id }
        store.updateBookmarkList(bookID: current.id, bookmarks: current.bookmarks)
    }
}

private struct SettingsSheet: View {
    @Binding var fontSize: CGFloat
    @Binding var lineSpacing: CGFloat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("字号") {
                    Slider(value: $fontSize, in: 12...30, step: 1)
                    Text("\(Int(fontSize)) pt").font(.caption).foregroundStyle(.secondary)
                }
                Section("行距") {
                    Slider(value: $lineSpacing, in: 0...20, step: 1)
                    Text("\(Int(lineSpacing))") .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("排版")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct BookmarksSheet: View {
    @Binding var book: Book
    var onJump: (Int) -> Void
    var onAdd: () -> Void
    var onDelete: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onAdd()
                } label: {
                    Label("在当前位置添加书签", systemImage: "bookmark.fill")
                }
                ForEach(book.bookmarks) { bm in
                    Button {
                        onJump(bm.offset)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bm.snippet.isEmpty ? "（空白位置）" : bm.snippet).lineLimit(2)
                            Text(bm.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { onDelete(bm.id) } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("书签")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}