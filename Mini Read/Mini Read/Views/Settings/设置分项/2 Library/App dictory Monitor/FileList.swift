//
//  FileListView.swift
//  Vellium
//
//  Created by piednes on 23/04/2025.
//

import SwiftUI

struct FileItem: Identifiable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    // ✅ init 不再调用 FileManager，只是简单赋值
    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

extension String {
    /// 返回文件名的扩展名（不包含 “.”），若没有则返回 ""
    var fileExtension: String {
        URL(fileURLWithPath: self).pathExtension
    }
}

// View that lists contents of a directory
struct DirectoryListView: View {
    let directoryURL: URL
    @State private var items: [FileItem] = []

    var body: some View {
        List(items) { item in
            if item.isDirectory {
                NavigationLink(destination: DirectoryListView(directoryURL: item.url)) {
                    Label(item.url.lastPathComponent, systemImage: "folder")
                }
            } else {
                HStack {
                    Label(item.url.lastPathComponent, systemImage: "doc.text")
                    Spacer()
                }
                .onTapGesture {
                    // Handle file tap (e.g., open or preview)
                    print("Tapped file: \(item.url.lastPathComponent)")
                }
            }
        }
        .modifier(CustomListModifier(title: directoryURL.lastPathComponent))
        .onAppear(perform: loadContents)
    }
    
    private func loadContents() {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],  // ✅ 预加载属性
                options: [.skipsHiddenFiles]
            )
            self.items = urls.compactMap { url -> FileItem? in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return FileItem(url: url, isDirectory: isDir)
            }.sorted { lhs, rhs in
                if lhs.isDirectory == rhs.isDirectory {
                    return lhs.url.lastPathComponent.lowercased() < rhs.url.lastPathComponent.lowercased()
                }
                return lhs.isDirectory && !rhs.isDirectory
            }
        } catch {
            print("Error reading directory: \(error)")
            self.items = []
        }
    }
}



