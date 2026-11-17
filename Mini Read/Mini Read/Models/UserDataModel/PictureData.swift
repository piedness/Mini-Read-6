//
//  PictureData.swift
//  TheNewVellium
//
//  Created by Max Piednes on 2026/5/3.
//

import Foundation
import SwiftData

@Model
final class UserBackgroundImage {
    var id: UUID
    var fileName: String
    var createdAt: Date
    
    init(fileName: String) {
        self.id = UUID()
        self.fileName = fileName
        self.createdAt = Date()
    }
}

// 在你的 AppSettings 模型中增加：
// var maxImageCacheCount: Int = 5
