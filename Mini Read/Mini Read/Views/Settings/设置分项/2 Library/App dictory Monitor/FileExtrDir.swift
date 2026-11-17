//
//  FileExtrDir.swift
//  TheNewVellium
//
//  Created by Max Piednes on 2026/4/25.
//

import SwiftUI
import SwiftData

struct FileExtrDirView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        sort: [ SortDescriptor(\bookItem.dateAdded, order: .reverse) ]
    ) private var items: [bookItem]
    
    @State private var isArmed = false

    var body: some View {
        
        List {
            ForEach(items) { item in
                NavigationLink(item.bookExtrSubdir.absoluteString) {
                    DirectoryListView(directoryURL: item.bookExtrSubdir)
                }
            }
            .onDelete(perform: deleteItems)
        }
        .modifier(CustomListModifier(title: "File Extr Dir"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
            
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    if isArmed {
                        deleteAllItems()
                        isArmed = false
                    } else {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            isArmed = true
                        }
                    }
                } label: {
                    ZStack {
                        if isArmed {
                            Text("确认删除")
                                .transition(.blurReplace)
                        } else {
                            Text("删除全部")
                                .transition(.blurReplace)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(isArmed ? .red : .blue)
                .animation(.easeInOut(duration: 0.22), value: isArmed)
            }
        }

    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                deleteDirectory(at: items[index].bookExtrSubdir)
                deleteDirectory(at: items[index].bookBackupdir)
                modelContext.delete(items[index])
            }
        }
    }
    
    private func deleteAllItems() {
        withAnimation {
            for item in items {
                deleteDirectory(at: item.bookExtrSubdir)
                deleteDirectory(at: item.bookBackupdir)
                modelContext.delete(item)
            }
        }
    }
}
