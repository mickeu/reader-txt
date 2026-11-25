import Foundation
import Combine
import UIKit

/// 书架与持久化。索引文件沿用旧版：`Documents/books.json`（`[Book]` 的 JSON 数组）。
final class BookStore: ObservableObject {
    static let shared = BookStore()

    @Published private(set) var books: [Book] = []

    /// 一次性提示（导入失败原因等），由 UI 消费。
    @Published var lastError: String?

    private let fm = FileManager.default
    private let io = DispatchQueue(label: "reader.store.io", qos: .userInitiated)
    private var didLoad = false

    /// 单文件上限，防止误导入超大文件导致内存暴涨。
    private let maxImportBytes = 64 * 1024 * 1024

    // MARK: - 路径

    private var documentsURL: URL? {
        fm.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private var indexURL: URL? {
        documentsURL?.appendingPathComponent("books.json")
    }

    private var inboxURL: URL? {
        documentsURL?.appendingPathComponent("Inbox", isDirectory: true)
    }

    private func textURL(for book: Book) -> URL? {
        guard !book.fileName.isEmpty else { return nil }
        // 只取最后一段，杜绝 "../" 之类的路径穿越。
        let name = (book.fileName as NSString).lastPathComponent
        guard name != ".", name != "..", !name.isEmpty else { return nil }
        return documentsURL?.appendingPathComponent(name)
    }

    // MARK: - 载入 / 保存

    /// 首次进入时调用；重复调用安全。
    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        io.async { [weak self] in
            guard let self else { return }
            let loaded = self.readIndex()
            DispatchQueue.main.async { self.books = loaded }
        }
    }

    private func readIndex() -> [Book] {
        guard let url = indexURL, fm.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode([Book].self, from: data)
        } catch {
            // 索引损坏时不要清空用户的文件，只从空书架开始并提示。
            DispatchQueue.main.async { self.lastError = "书架索引损坏，已忽略：\(error.localizedDescription)" }
            return []
        }
    }

    /// 原子写索引；失败只提示，不影响内存中的书架。
    private func saveIndex() {
        let snapshot = books
        io.async { [weak self] in
            guard let self, let url = self.indexURL else { return }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                DispatchQueue.main.async { self.lastError = "保存书架失败：\(error.localizedDescription)" }
            }
        }
    }

    // MARK: - 导入

    /// 从任意来源（文件选择器 / 分享 / Inbox）导入一个 txt。
    /// 阻断重复：同名且同大小的已存在书籍直接复用，不重复复制。
    /// 返回值仅表示「已排队」；真正结果通过 onDone 回调，避免主线程做大文件 I/O。
    @discardableResult
    func importFile(at url: URL, onDone: ((Bool) -> Void)? = nil) -> Bool {
        let snapshot = books
        io.async { [weak self] in
            guard let self else { return }
            let outcome = self.performImport(at: url, snapshot: snapshot)
            DispatchQueue.main.async {
                if let err = outcome.error { self.lastError = err }
                onDone?(outcome.ok)
            }
        }
        return true
    }

    /// `onOpenURL` 入口；不认识的 URL 直接忽略。
    func importExternal(_ url: URL) {
        guard url.isFileURL else { return }
        _ = importFile(at: url)
    }

    /// 启动与回到前台时扫 `Documents/Inbox`（iOS 分享「拷贝到」的落点）。
    /// 导入成功后删除 Inbox 源文件，避免重复处理。
    func scanInbox() {
        let snapshot = books
        io.async { [weak self] in
            guard let self, let inbox = self.inboxURL else { return }
            let contents = (try? self.fm.contentsOfDirectory(at: inbox,
                                                            includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles])) ?? []
            guard !contents.isEmpty else { return }
            for url in contents {
                let outcome = self.performImport(at: url, snapshot: snapshot)
                if outcome.ok {
                    try? self.fm.removeItem(at: url)
                } else if let err = outcome.error {
                    DispatchQueue.main.async { self.lastError = err }
                }
            }
        }
    }

    /// 只在 io 队列调用。`snapshot` 是本轮开始时的书架快照，避免跨线程读 @Published。
    private func performImport(at url: URL, snapshot: [Book]) -> (ok: Bool, error: String?) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let docs = documentsURL else { return (false, "找不到文档目录") }
        let name = (url.lastPathComponent as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return (false, "文件名无效") }

        var data: Data
        do {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if size > maxImportBytes { return (false, "文件超过 64 MB，暂不支持") }
            if size == 0 { return (false, "文件是空的") }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return (false, "读取失败：\(error.localizedDescription)")
        }

        guard let text = Self.decode(data: data), !text.isEmpty else {
            return (false, "无法识别为文本文件（可能是二进制或空文件）")
        }

        var targetName = name
        let existingURL = docs.appendingPathComponent(targetName)
        if fm.fileExists(atPath: existingURL.path) {
            let existingSize = (try? fm.attributesOfItem(atPath: existingURL.path)[.size] as? NSNumber)?.intValue
            if snapshot.contains(where: { $0.fileName == targetName }), existingSize == data.count {
                return (true, nil)   // 同一本书重复导入，直接视为成功
            }
            targetName = Self.uniqueName(base: name, in: docs, fm: fm)
        }

        do {
            try data.write(to: docs.appendingPathComponent(targetName), options: .atomic)
        } catch {
            return (false, "写入失败：\(error.localizedDescription)")
        }

        var book = Book(title: Self.title(from: targetName, text: text), fileName: targetName)
        Self.fill(book: &book, text: text)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.books.removeAll { $0.fileName == targetName }
            self.books.append(book)
            self.saveIndex()
        }
        return (true, nil)
    }

    // MARK: - 删除 / 修复

    func delete(_ book: Book) {
        if let url = textURL(for: book) {
            do { try fm.removeItem(at: url) } catch {
                // 文件删除失败仍然移除索引项，避免书架残留幽灵条目。
                DispatchQueue.main.async { self.lastError = "删除文件失败：\(error.localizedDescription)" }
            }
        }
        BookCache.purgePages(bookID: book.id)
        books.removeAll { $0.id == book.id }
        saveIndex()
        NotificationCenter.default.post(name: .readerShelfChanged, object: nil)
    }

    /// 检查索引里记录的文件是否还在；缺失的标记为未准备，不再假装能打开。
    func prepareMissing() {
        let snapshotIn = books            // Called on the main actor by the view.
        io.async { [weak self] in
            guard let self else { return }
            var changed = false
            var snapshot = snapshotIn
            for var book in snapshot {
                guard let url = self.textURL(for: book) else { continue }
                let exists = self.fm.fileExists(atPath: url.path)
                if !exists && book.prepared {
                    book.prepared = false
                    changed = true
                    if let i = snapshot.firstIndex(where: { $0.id == book.id }) { snapshot[i] = book }
                }
            }
            if changed {
                DispatchQueue.main.async { self.books = snapshot; self.saveIndex() }
            }
        }
    }

    // MARK: - 文本

    /// 读取一本书的全文；文件缺失返回 nil。
    func text(for book: Book) -> String? {
        guard let url = textURL(for: book), fm.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return Self.decode(data: data)
    }

    /// 编码识别：UTF-8 → UTF-16(BOM) → GB18030 → 单字节兜底。
    static func decode(data: Data) -> String? {
        if data.isEmpty { return nil }
        // 明显二进制（前 8KB 里出现 NUL 且不是 UTF-16 BOM）时直接拒绝。
        let head = data.prefix(8192)
        let hasBOM16 = data.count >= 2 && ((data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF))
        if !hasBOM16 && head.contains(0) { return nil }

        if let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
        if hasBOM16, let s = String(data: data, encoding: .utf16), !s.isEmpty { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)), !s.isEmpty { return s }
        if let s = String(data: data, encoding: .isoLatin1), !s.isEmpty { return s }
        return nil
    }

    /// 章节解析：行首匹配「第X章/回/节/卷」或 Chapter N。
    static func parseChapters(_ text: String) -> [Chapter] {
        var result: [Chapter] = []
        let pattern = #"^\s*(第\s*[0-9零一二三四五六七八九十百千两]+\s*[章回节卷部篇]|Chapter\s+\d+|CHAPTER\s+\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return result }
        let ns = text as NSString
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, m.range.location != NSNotFound, m.range.location < ns.length else { return }
            let lineRange = ns.lineRange(for: NSRange(location: m.range.location, length: 0))
            var title = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if title.count > 40 { title = String(title.prefix(40)) }
            result.append(Chapter(title: title.isEmpty ? "第 \(result.count + 1) 章" : title, location: m.range.location))
        }
        return result
    }

    static func fill(book: inout Book, text: String) {
        book.charCount = text.count
        book.chapters = parseChapters(text)
        book.prepared = true
        book.updatedAt = Date()
    }

    /// 从文件内容推断标题：取第一行非空文本，过长则退回文件名。
    static func title(from fileName: String, text: String) -> String {
        for line in text.split(separator: "\n", maxSplits: 8, omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            return t.count > 40 ? String(t.prefix(40)) : t
        }
        return (fileName as NSString).deletingPathExtension
    }

    static func uniqueName(base: String, in dir: URL, fm: FileManager) -> String {
        let ext = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        var i = 2
        while i < 1000 {
            let candidate = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            if !fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) { return candidate }
            i += 1
        }
        return "\(stem)-\(UUID().uuidString.prefix(8)).\(ext)"
    }

    // MARK: - 阅读页回写

    /// 阅读进度回写：只更新索引里的 lastOffset / lastChapterIndex，不重排章节。
    func updateProgress(bookID: UUID, offset: Int, chapter: Int) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].lastOffset = max(0, offset)
        books[i].lastChapterIndex = max(0, chapter)
        books[i].updatedAt = Date()
        saveIndex()
    }

    /// 书签列表回写。
    func updateBookmarkList(bookID: UUID, bookmarks: [Bookmark]) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].bookmarks = bookmarks
        books[i].updatedAt = Date()
        saveIndex()
    }

    /// 章节准备（导入后已同步完成；打开旧书时补一次）。
    func prepare(book: Book, text: String) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        var b = books[i]
        Self.fill(book: &b, text: text)
        books[i] = b
        saveIndex()
    }
}


extension Notification.Name {
    static let readerShelfChanged = Notification.Name("reader.shelfChanged")
}