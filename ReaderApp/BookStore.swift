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
    @discardableResult
    func importFile(at url: URL, onDone: ((Bool) -> Void)? = nil) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let docs = documentsURL else {
            finish(false, error: "找不到文档目录", onDone: onDone)
            return false
        }

        let name = (url.lastPathComponent as NSString).lastPathComponent
        guard !name.isEmpty else {
            finish(false, error: "文件名无效", onDone: onDone)
            return false
        }

        // 读入数据（带大小上限，先看属性再读，避免大文件爆内存）。
        var data: Data
        do {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if size > maxImportBytes {
                finish(false, error: "文件超过 64 MB，暂不支持", onDone: onDone)
                return false
            }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            finish(false, error: "读取失败：\(error.localizedDescription)", onDone: onDone)
            return false
        }

        guard let text = Self.decode(data: data), !text.isEmpty else {
            finish(false, error: "无法识别为文本文件（可能是二进制或空文件）", onDone: onDone)
            return false
        }

        // 目标文件名：重名时自动加序号，绝不覆盖已有文件。
        var targetName = name
        var targetURL = docs.appendingPathComponent(targetName)
        if fm.fileExists(atPath: targetURL.path) {
            let existing = books.first { $0.fileName == targetName }
            let sameSize = (try? fm.attributesOfItem(atPath: targetURL.path)[.size] as? NSNumber)?.intValue == data.count
            if existing != nil && sameSize {
                // 同一本书重复导入：刷新准备状态即可。
                if let i = books.firstIndex(where: { $0.fileName == targetName }) {
                    books[i].updatedAt = Date()
                    saveIndex()
                }
                finish(true, error: nil, onDone: onDone)
                return true
            }
            targetName = Self.uniqueName(base: name, in: docs, fm: fm)
            targetURL = docs.appendingPathComponent(targetName)
        }

        do {
            try data.write(to: targetURL, options: .atomic)
        } catch {
            finish(false, error: "写入失败：\(error.localizedDescription)", onDone: onDone)
            return false
        }

        var book = Book(title: Self.title(from: targetName, text: text), fileName: targetName)
        book.charCount = text.count
        Self.fill(book: &book, text: text)
        books.append(book)
        saveIndex()
        finish(true, error: nil, onDone: onDone)
        return true
    }

    /// `onOpenURL` 与 Inbox 共用入口；不认识的 URL 直接忽略。
    func importExternal(_ url: URL) {
        guard url.isFileURL else { return }
        _ = importFile(at: url)
    }

    /// 启动与回到前台时扫 `Documents/Inbox`（iOS 分享「拷贝到」落点）。
    /// 导入成功后删除 Inbox 中的源文件，避免下次重复处理。
    func scanInbox() {
        io.async { [weak self] in
            guard let self, let inbox = self.inboxURL else { return }
            let contents = (try? self.fm.contentsOfDirectory(at: inbox,
                                                            includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles])) ?? []
            for url in contents where url.pathExtension.lowercased() != "" || true {
                let ok = self.importSynchronously(at: url)
                if ok {
                    try? self.fm.removeItem(at: url)
                }
            }
        }
    }

    /// 供 Inbox 使用的同步版本（已在 io 队列上，不能再套队列）。
    private func importSynchronously(at url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maxImportBytes,
              let text = Self.decode(data: data), !text.isEmpty else { return false }

        let name = (url.lastPathComponent as NSString).lastPathComponent
        guard let docs = documentsURL, !name.isEmpty else { return false }

        var targetName = name
        if fm.fileExists(atPath: docs.appendingPathComponent(targetName).path) {
            let existing = books.first { $0.fileName == targetName }
            let sameSize = (try? fm.attributesOfItem(atPath: docs.appendingPathComponent(targetName).path)[.size] as? NSNumber)?.intValue == data.count
            if existing != nil && sameSize { return true }   // 已导入过，清掉 Inbox 即可
            targetName = Self.uniqueName(base: name, in: docs, fm: fm)
        }
        do {
            try data.write(to: docs.appendingPathComponent(targetName), options: .atomic)
        } catch { return false }

        var book = Book(title: Self.title(from: targetName, text: text), fileName: targetName)
        book.charCount = text.count
        Self.fill(book: &book, text: text)
        DispatchQueue.main.async {
            self.books.removeAll { $0.fileName == targetName }
            self.books.append(book)
            self.saveIndex()
        }
        return true
    }

    private func finish(_ ok: Bool, error: String?, onDone: ((Bool) -> Void)?) {
        DispatchQueue.main.async {
            if let error { self.lastError = error }
            onDone?(ok)
        }
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
        io.async { [weak self] in
            guard let self else { return }
            var changed = false
            var snapshot: [Book] = []
            DispatchQueue.main.sync { snapshot = self.books }
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