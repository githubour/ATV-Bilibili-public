//
//  String+Extensions.swift
//  ATV-Bilibili
//
//  Created by whw on 2022/10/31.
//

import Foundation

extension String {
    /// 数字字符串自增/自减：点赞/投币/收藏按钮标题直接展示计数并原地 ±1
    static func += (lhs: inout String, rhs: Int) {
        if let number = Int(lhs) {
            lhs = String(number + rhs)
        }
    }

    static func -= (lhs: inout String, rhs: Int) {
        if let number = Int(lhs) {
            lhs = String(number - rhs)
        }
    }

    func isMatch(pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            Logger.warn("非法正则: \(pattern)")
            return false
        }
        return regex.firstMatch(in: self, options: [], range: NSMakeRange(0, utf16.count)) != nil
    }

    func removingHTMLTags() -> String {
        return replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
    }
}

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { return self }
}
