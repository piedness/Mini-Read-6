//
//  AppDirectoryMonitor.swift
//  Vellium
//
//  Created by piednes on 25/04/2025.
//

import SwiftUI
import SwiftData

struct AppDirectoryMonitorView: View {

    var body: some View {
        NavigationLink("App Directory Monitor"){

            List{
                Section {
                    NavigationLink("Root"){
                        List{
                            Section {
                                // ✅ 替换为独立子 View
                                NavigationLink("File Extr Dir") {
                                    FileExtrDirView()
                                }
                            } header: {
                                Text("解压目录")
                            }

                        }
                        .modifier(CustomListModifier(title: "Root"))
                    }
                } header: {
                    Text("根目录")
                }
            }
            .modifier(CustomListModifier(title: "App Directory Monitor"))
        }
    }

}
