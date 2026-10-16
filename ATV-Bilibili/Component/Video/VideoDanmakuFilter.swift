//
//  VideoDanmakuFilter.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2024/12/13.
//

import UIKit

class VideoDanmakuFilter {
    static let shared = VideoDanmakuFilter()

    private var stringFilters = [String]()
    private var regexFilters = [Regex<AnyRegexOutput>]()
    private var localStringFilters = [String]()
    private init() {
        refreshCache(rules: VideoDanmakuFilterStorage.filters)
        rebuildLocalFilters()
    }

    func accept(_ danmaku: String) -> Bool {
        let loweredDanmaku = danmaku.lowercased()
        for filter in localStringFilters {
            if loweredDanmaku.contains(filter) {
                return false
            }
        }

        for filter in stringFilters {
            if loweredDanmaku.contains(filter) {
                return false
            }
        }

        for filter in regexFilters {
            if danmaku.contains(filter) {
                return false
            }
        }
        return true
    }

    // MARK: 本地自定义屏蔽词

    var localFilterCount: Int {
        Settings.localDanmakuFilters.count
    }

    func addLocalFilter(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var words = Settings.localDanmakuFilters
        guard !words.contains(trimmed) else { return }
        words.append(trimmed)
        Settings.localDanmakuFilters = words
        rebuildLocalFilters()
    }

    func removeLocalFilter(_ word: String) {
        Settings.localDanmakuFilters.removeAll { $0 == word }
        rebuildLocalFilters()
    }

    private func rebuildLocalFilters() {
        // 与云端关键字同规则：小写包含匹配
        localStringFilters = Settings.localDanmakuFilters.map { $0.lowercased() }
    }

    func autoUpdate() {
        guard Settings.enableDanmakuFilter else { return }
        if Date().timeIntervalSince(VideoDanmakuFilterStorage.lastUpdate) > 60 * 60 * 24 {
            Task {
                await update()
            }
        }
    }

    @discardableResult
    func update() async -> String {
        VideoDanmakuFilterStorage.lastUpdate = Date()
        do {
            let data = try await WebRequest.requestDanmakuFilterList()
            let rules = data.rule.filter({ $0.type == 0 || $0.type == 1 })
            VideoDanmakuFilterStorage.filters = rules
            refreshCache(rules: rules)
            let keywordCnt = rules.filter { $0.type == 0 }.count
            let regexCnt = rules.filter { $0.type == 1 }.count
            return "已同步\(rules.count)条屏蔽规则（关键字\(keywordCnt)条，正则\(regexCnt)条）"
        } catch let err {
            return "同步失败：\(err)"
        }
    }

    var syncStatusDescription: String {
        let total = stringFilters.count + regexFilters.count
        guard total > 0 else {
            return "未同步"
        }
        return "已同步\(total)条 · \(DateFormatter.shortDateTime.string(from: VideoDanmakuFilterStorage.lastUpdate))"
    }

    private func refreshCache(rules: [VideoDanmakuFilterData.Rule]) {
        stringFilters.removeAll()
        regexFilters.removeAll()
        for filter in rules {
            switch filter.type {
            case 0:
                stringFilters.append(filter.filter.lowercased())
            case 1:
                if let regex = try? Regex(filter.filter) {
                    regexFilters.append(regex)
                } else {
                    Logger.warn("[dm] 无法解析屏蔽正则规则: \(filter.filter)")
                }
            default:
                break
            }
        }
    }
}

private enum VideoDanmakuFilterStorage {
    @UserDefaultCodable(.danmakuFilters, defaultValue: [])
    static var filters: [VideoDanmakuFilterData.Rule]

    @UserDefault(.danmakuFilterLastUpdate, defaultValue: Date(timeIntervalSince1970: 0))
    static var lastUpdate: Date
}

private struct VideoDanmakuFilterData: Codable {
    struct Rule: Codable {
        let filter: String
        let type: Int
    }

    let rule: [Rule]
    let toast: String?
}

private extension WebRequest {
    static func requestDanmakuFilterList() async throws -> VideoDanmakuFilterData {
        try await request(url: EndPoint.danmakuFilter)
    }
}
