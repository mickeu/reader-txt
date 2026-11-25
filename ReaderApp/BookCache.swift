import Foundation

/// 分页与进度的磁盘缓存。全部 JSON，失败静默降级（读不到就重新分页）。
enum BookCache {
    struct PageRecord: Codable {
        var page: Int
        var offset: Int
        var length: Int
    }

    private static let fm = FileManager.default
    private static let io = DispatchQueue(label: "reader.cache.io", qos: .utility)

    private static var root: URL? {
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent("ReaderCache", isDirectory: true)
    }

    private static func dir(for bookID: UUID) -> URL? {
        root?.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    private static func key(fontSize: CGFloat, lineSpacing: CGFloat, size: CGSize) -> String {
        String(format: "p_%.1f_%.1f_%.0fx%.0f", fontSize, lineSpacing, size.width, size.height)
    }

    // MARK: - 分页

    static func loadPages(bookID: UUID, fontSize: CGFloat, lineSpacing: CGFloat, size: CGSize) -> [Paginator.Page]? {
        guard size.width > 0, size.height > 0, let d = dir(for: bookID) else { return nil }
        let url = d.appendingPathComponent(key(fontSize: fontSize, lineSpacing: lineSpacing, size: size) + ".json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let records = try? JSONDecoder().decode([PageRecord].self, from: data),
              !records.isEmpty else { return nil }
        return records.map { Paginator.Page(offset: $0.offset, length: $0.length) }
    }

    static func storePages(_ pages: [Paginator.Page], bookID: UUID,
                           fontSize: CGFloat, lineSpacing: CGFloat, size: CGSize) {
        guard !pages.isEmpty, size.width > 0, size.height > 0, let d = dir(for: bookID) else { return }
        let records = pages.enumerated().map { PageRecord(page: $0.offset, offset: $0.element.offset, length: $0.element.length) }
        io.async {
            do {
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(records)
                try data.write(to: d.appendingPathComponent(key(fontSize: fontSize, lineSpacing: lineSpacing, size: size) + ".json"),
                               options: .atomic)
            } catch {
                // 缓存失败不影响阅读。
            }
        }
    }

    // MARK: - 进度

    struct Progress: Codable {
        var offset: Int
        var chapter: Int
    }

    static func loadProgress(bookID: UUID) -> (offset: Int, chapter: Int)? {
        guard let d = dir(for: bookID) else { return nil }
        let url = d.appendingPathComponent("progress.json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let p = try? JSONDecoder().decode(Progress.self, from: data) else { return nil }
        return (max(0, p.offset), max(0, p.chapter))
    }

    static func storeProgress(bookID: UUID, offset: Int, chapter: Int) {
        guard let d = dir(for: bookID) else { return }
        let p = Progress(offset: max(0, offset), chapter: max(0, chapter))
        io.async {
            do {
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(p)
                try data.write(to: d.appendingPathComponent("progress.json"), options: .atomic)
            } catch {
                // 进度写失败只影响下次续读位置。
            }
        }
    }

    // MARK: - 清理

    static func purgePages(bookID: UUID) {
        guard let d = dir(for: bookID) else { return }
        io.async { try? fm.removeItem(at: d) }
    }

    static func purgeAll() {
        guard let r = root else { return }
        io.async { try? fm.removeItem(at: r) }
    }
}