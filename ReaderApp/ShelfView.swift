import SwiftUI
import UIKit

/// 书架：网格封面、搜索、导入、删除、长按菜单。
struct ShelfView: View {
    @EnvironmentObject private var store: BookStore
    @State private var search = ""
    @State private var showPicker = false
    @State private var importError: String?
    @State private var importing = false
    @State private var openBook: Book?

    private var filtered: [Book] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = q.isEmpty ? store.books : store.books.filter { $0.title.localizedCaseInsensitiveContains(q) }
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("读书")
                .searchable(text: $search, prompt: "搜索书名")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showPicker = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("导入 txt")
                    }
                }
                .sheet(isPresented: $showPicker) {
                    DocumentPicker { urls in
                        importFiles(urls)
                    }
                }
                .fullScreenCover(item: $openBook) { book in
                    ReaderView(book: book)
                        .environmentObject(store)
                }
                .alert("导入失败", isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                )) {
                    Button("好", role: .cancel) { importError = nil }
                } message: {
                    Text(importError ?? "")
                }
                .overlay {
                    if importing {
                        ProgressView("导入中…")
                            .padding(20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.books.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 16)], spacing: 20) {
                    ForEach(filtered) { book in
                        Button {
                            openBook = book
                        } label: {
                            BookCell(book: book)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                store.delete(book)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("书架是空的")
                .font(.headline)
            Text("点右上角 + 导入 txt，或在别处分享文件时选「读书」")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importing = true
        var remaining = urls.count
        for url in urls {
            _ = store.importFile(at: url) { ok in
                remaining -= 1
                if !ok, importError == nil {
                    importError = store.lastError ?? "导入失败"
                }
                if remaining <= 0 { importing = false }
            }
        }
    }
}

private struct BookCell: View {
    let book: Book

    var body: some View {
        VStack(spacing: 6) {
            CoverView(book: book)
                .frame(width: 104, height: 148)
            Text(book.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
        }
    }
}

/// 封面：渐变色块 + 书名首字，不依赖外部图片。
struct CoverView: View {
    let book: Book

    var body: some View {
        let hue = book.coverHue
        RoundedRectangle(cornerRadius: 8)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.45, brightness: 0.85),
                        Color(hue: hue, saturation: 0.65, brightness: 0.55),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .topLeading) {
                Text(String(book.title.prefix(1)))
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(10)
            }
            .overlay(alignment: .bottom) {
                if book.prepared == false {
                    Text("缺失")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.45))
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}