//
//  deleteDir.swift
//  Vellium
//
//  Created by piednes on 23/04/2025.
//

import Foundation

/// 删除指定路径下的整个目录及其所有文件
func deleteDirectory(at path: URL) {
    let dirURL = path
    print("删除目录：\(dirURL)")
    do {
        // 直接删掉整个目录，包括其中所有文件和子目录
        try FileManager.default.removeItem(at: dirURL)
        print("✅ 已删除目录及其内容：\(path)")
    } catch {
        print("❌ 删除目录失败：", error.localizedDescription)
    }
}
