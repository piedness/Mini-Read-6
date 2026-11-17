//
//  ColorAdaptive.swift
//  swiftUI0907
//
//  Created by Max Piednes on 2025/9/20.
//

import SwiftUI

extension Color {
    static var adaptiveTint: Color {
        Color(UIColor { traitCollection in
            return traitCollection.userInterfaceStyle == .dark ? UIColor.white : UIColor.black
        })
    }
}
