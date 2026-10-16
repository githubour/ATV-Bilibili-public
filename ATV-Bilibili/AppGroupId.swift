//
//  AppGroupId.swift
//  ATV-Bilibili
//
//  App Group 由构建时注入的 APP_BUNDLE_ID 推导:
//  不同 bundle id 的构建天然各自隔离, Top Shelf 数据互不覆盖
//

import Foundation

enum AppGroupId {
    /// 当前构建的 App Group 标识(来自构建注入, 不再硬编码)
    static var current: String {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String,
              !id.isEmpty
        else {
            assertionFailure("AppGroupId 缺失, 请检查构建配置(APP_BUNDLE_ID)")
            return "group.com.example.bilibilitv"
        }
        return id
    }
}
