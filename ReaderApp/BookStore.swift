import Foundation
import SwiftUI

/// Shelf + persistence. Placeholder until the reverse-engineered spec lands.
final class BookStore: ObservableObject {
    @Published var books: [Book] = []
    func importExternal(_ url: URL) { _ = url }
}

struct Book: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var fileName: String
}
