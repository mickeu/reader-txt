import Foundation

/// 一本书。字段名与旧版 `books.json` 保持一致，保证老书架数据能直接读。
struct Book: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var fileName: String
    var coverHue: Double = 0.55
    var lastOffset: Int = 0
    var lastChapterIndex: Int = 0
    var updatedAt: Date = Date()
    var chapters: [Chapter] = []
    var bookmarks: [Bookmark] = []
    var charCount: Int = 0
    var prepared: Bool = false

    /// 兼容旧数据：缺字段时给出默认值，避免整库解码失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decode(String.self, forKey: .title)) ?? "未命名"
        fileName = (try? c.decode(String.self, forKey: .fileName)) ?? ""
        coverHue = (try? c.decode(Double.self, forKey: .coverHue)) ?? 0.55
        lastOffset = (try? c.decode(Int.self, forKey: .lastOffset)) ?? 0
        lastChapterIndex = (try? c.decode(Int.self, forKey: .lastChapterIndex)) ?? 0
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
        chapters = (try? c.decode([Chapter].self, forKey: .chapters)) ?? []
        bookmarks = (try? c.decode([Bookmark].self, forKey: .bookmarks)) ?? []
        charCount = (try? c.decode(Int.self, forKey: .charCount)) ?? 0
        prepared = (try? c.decode(Bool.self, forKey: .prepared)) ?? false
    }

    init(title: String, fileName: String) {
        self.title = title
        self.fileName = fileName
        self.coverHue = Self.hue(for: fileName)
    }

    /// 稳定的封面色，同一文件名永远同一颜色。
    static func hue(for name: String) -> Double {
        var hash: UInt64 = 1469598103934665603
        for byte in name.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return Double(hash % 360) / 360.0
    }
}

/// 目录章节。
struct Chapter: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var location: Int

    init(title: String, location: Int) {
        self.title = title
        self.location = location
    }
}

/// 书签。
struct Bookmark: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var bookID: UUID = UUID()
    var snippet: String = ""
    var offset: Int = 0
    var length: Int = 0
    var createdAt: Date = Date()
}