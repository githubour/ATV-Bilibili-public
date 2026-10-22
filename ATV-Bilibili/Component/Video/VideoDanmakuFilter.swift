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
    private var userHashFilters = Set<String>()
    private var localStringFilters = [String]()
    private var localRegexFilters = [Regex<AnyRegexOutput>]()
    private var builtinStringFilters = [String]()
    private var builtinRegexFilters = [Regex<AnyRegexOutput>]()
    private init() {
        refreshCache(rules: VideoDanmakuFilterStorage.filters)
        rebuildLocalFilters()
        rebuildBuiltinFilters()
    }

    /// 弹幕是否应保留。midHash 为发送者的 midHash，用于匹配「屏蔽用户」规则(type 2)
    func accept(_ danmaku: String, midHash: String) -> Bool {
        if !midHash.isEmpty, userHashFilters.contains(midHash.lowercased()) {
            return false
        }

        let loweredDanmaku = danmaku.lowercased()
        for filter in localStringFilters {
            if loweredDanmaku.contains(filter) {
                return false
            }
        }

        for regex in localRegexFilters {
            if danmaku.contains(regex) {
                return false
            }
        }

        for filter in builtinStringFilters {
            if loweredDanmaku.contains(filter) {
                return false
            }
        }

        for regex in builtinRegexFilters {
            if danmaku.contains(regex) {
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

    /// 批量导入本地屏蔽规则：按空白/换行/逗号(中英文)拆分，逐条去重后并入。
    /// 注意：正则条目内不要含空白字符，否则会被拆开。
    func importLocalFilters(from text: String) {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，、"))
        var words = Settings.localDanmakuFilters
        let before = words.count
        for token in text.components(separatedBy: separators) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !words.contains(trimmed) else { continue }
            words.append(trimmed)
        }
        guard words.count != before else { return }
        Settings.localDanmakuFilters = words
        rebuildLocalFilters()
    }

    func removeLocalFilter(_ word: String) {
        Settings.localDanmakuFilters.removeAll { $0 == word }
        rebuildLocalFilters()
    }

    private func rebuildLocalFilters() {
        localStringFilters.removeAll()
        localRegexFilters.removeAll()
        for entry in Settings.localDanmakuFilters {
            if let pattern = Self.regexPattern(from: entry) {
                if let regex = try? Regex(pattern) {
                    localRegexFilters.append(regex)
                } else {
                    Logger.warn("[dm] 无法解析本地屏蔽正则: \(entry)")
                }
            } else {
                // 与云端关键字同规则：小写包含匹配
                localStringFilters.append(entry.lowercased())
            }
        }
    }

    /// 本地规则约定：`/` 开头且 `/` 结尾(长度 > 2)的条目视为正则，返回其内部模式；否则返回 nil(按关键字处理)
    private static func regexPattern(from entry: String) -> String? {
        guard entry.count > 2, entry.hasPrefix("/"), entry.hasSuffix("/") else { return nil }
        return String(entry.dropFirst().dropLast())
    }

    /// 内置屏蔽规则(随 App 编译；公共仓库由「本机-导出公共版.command」的 SANITIZE 洗成空数组)
    private func rebuildBuiltinFilters() {
        builtinStringFilters = BuiltinDanmakuFilters.keywords.map { $0.lowercased() }
        builtinRegexFilters = BuiltinDanmakuFilters.regexes.compactMap { pattern in
            guard let regex = try? Regex(pattern) else {
                Logger.warn("[dm] 无法解析内置屏蔽正则: \(pattern)")
                return nil
            }
            return regex
        }
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
        do {
            let data = try await WebRequest.requestDanmakuFilterList()
            // 保留三类：关键字(0) / 正则(1) / 用户(2)。type 2 的 filter 为发送者 midHash
            let rules = data.rule.filter { $0.type == 0 || $0.type == 1 || $0.type == 2 }
            VideoDanmakuFilterStorage.filters = rules
            // 只有成功才记同步时间：失败也写的话，24h 节流会把下一次重试直接压掉。
            VideoDanmakuFilterStorage.lastUpdate = Date()
            refreshCache(rules: rules)
            let keywordCnt = rules.filter { $0.type == 0 }.count
            let regexCnt = rules.filter { $0.type == 1 }.count
            let userCnt = rules.filter { $0.type == 2 }.count
            return "已同步\(rules.count)条屏蔽规则（关键字\(keywordCnt)条，正则\(regexCnt)条，用户\(userCnt)条）"
        } catch let err {
            return "同步失败：\(err)"
        }
    }

    /// 换号时清空随账号走的云端屏蔽词（本地/内置词保留），同步时间戳归零，下次进弹幕页会重新拉取
    func resetCloudRules() {
        VideoDanmakuFilterStorage.filters = []
        VideoDanmakuFilterStorage.lastUpdate = Date(timeIntervalSince1970: 0)
        refreshCache(rules: [])
    }

    var syncStatusDescription: String {
        let total = stringFilters.count + regexFilters.count + userHashFilters.count
        guard total > 0 else {
            return "未同步"
        }
        return "已同步\(total)条 · \(DateFormatter.shortDateTime.string(from: VideoDanmakuFilterStorage.lastUpdate))"
    }

    private func refreshCache(rules: [VideoDanmakuFilterData.Rule]) {
        stringFilters.removeAll()
        regexFilters.removeAll()
        userHashFilters.removeAll()
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
            case 2:
                let hash = filter.filter.lowercased()
                if !hash.isEmpty {
                    userHashFilters.insert(hash)
                }
            default:
                break
            }
        }
    }
}

/// 内置弹幕屏蔽规则(个人防剧透主题词)，随 App 编译进私有仓库。
/// 公共仓库由「本机-导出公共版.command」的 SANITIZE 规则把下面两个数组洗成空数组。
/// ⚠️ keywords / regexes 必须各自保持**单行**(BSD sed 只做单行匹配，多行会洗不干净)。
enum BuiltinDanmakuFilters {
    static let keywords: [String] = []
    static let regexes: [String] = []
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
