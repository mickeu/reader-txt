import SwiftUI

struct ShelfView: View {
    @EnvironmentObject private var store: BookStore

    var body: some View {
        NavigationStack {
            List(store.books) { book in
                VStack(alignment: .leading) {
                    Text(book.title)
                    Text(book.fileName).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("读书")
        }
    }
}
