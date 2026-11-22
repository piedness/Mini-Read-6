//
//  deleteDir.swift
//  Vellium
//
//  Created by piednes on 23/04/2025.
//

import Foundation

/// 删除指定路径下的整个目录及其所有文件。
///
/// - Returns: `true` 表示"删完之后它确实不在了"——包括**本来就不存在**的情况。
///   调用方要用它区分"已经清干净"和"没删掉"，所以不存在不能算失败：
///   对"清空"这个目标而言，它已经是达成状态了。
///
/// 原实现返回 `Void` 且对不存在的路径也打一行"❌ 删除目录失败"，
/// 于是重复执行清理会刷出一串假错误，日志里再也看不出真正的失败。
@discardableResult
func deleteDirectory(at path: URL) -> Bool {
    let dirURL = path
    do {
        // 直接删掉整个目录，包括其中所有文件和子目录
        try FileManager.default.removeItem(at: dirURL)
        print("✅ 已删除目录及其内容：\(path)")
        return true
    } catch {
        // 本来就不在：这不是失败，安静地当作已完成。
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
            return true
        }
        print("❌ 删除目录失败：", error.localizedDescription)
        return false
    }
}
