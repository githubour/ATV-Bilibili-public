//
//  URL+Extensions.swift
//  ATV-Bilibili
//

import Foundation

extension URL {
    /// B站接口常回裸域名路径（如 `//i0.hdslb.com/...`），补上 https 才能交给 URLSession / Kingfisher。
    func addSchemeIfNeed() -> URL {
        if scheme == nil {
            return URL(string: "https:\(absoluteString)")!
        }
        return self
    }
}
