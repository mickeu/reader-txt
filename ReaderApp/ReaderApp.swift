import SwiftUI

@main
struct ReaderApp: App {
    @StateObject private var store = BookStore()

    var body: some Scene {
        WindowGroup {
            ShelfView()
                .environmentObject(store)
                .onOpenURL { store.importExternal($0) }
        }
    }
}
