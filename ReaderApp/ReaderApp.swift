import SwiftUI

@main
struct ReaderApp: App {
    @StateObject private var store = BookStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 让系统把分享进来的 txt 交给我们，而不是落到「无 App 处理」。
        BookStore.shared.loadIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ShelfView()
                .environmentObject(store)
                // 分享「拷贝到 读书」/「用读书打开」时走这里。
                .onOpenURL { url in
                    BookStore.shared.importExternal(url)
                }
                .task {
                    // 启动扫 Inbox：iOS 把分享的文件放进 Documents/Inbox，旧版没处理。
                    BookStore.shared.scanInbox()
                    BookStore.shared.prepareMissing()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                BookStore.shared.scanInbox()
            }
        }
    }
}