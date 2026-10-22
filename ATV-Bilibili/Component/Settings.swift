//
//  Settings.swift
//  ATV-Bilibili
//
//  Created by whw on 2022/10/19.
//

import Combine
import Foundation
import SwiftUI

enum FeedDisplayStyle: Codable, CaseIterable {
    case large
    case normal
    case sideBar

    var hideInSetting: Bool {
        self == .sideBar
    }
}

final class Defaults {
    static let shared = Defaults()

    @Published private(set) var showDanmaku: Bool

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let initial = UserDefaults.standard.object(forKey: SettingsKey.danmakuStatus.rawValue) as? Bool ?? true
        _showDanmaku = Published(initialValue: initial)
        $showDanmaku
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: SettingsKey.danmakuStatus.rawValue) }
            .store(in: &cancellables)
    }

    func setShowDanmaku(_ value: Bool) {
        showDanmaku = value
    }

    func toggleShowDanmaku() {
        showDanmaku.toggle()
    }
}

enum Settings {
    @UserDefaultCodable(.displayStyle, defaultValue: .normal)
    static var displayStyle: FeedDisplayStyle

    @UserDefault(.directlyEnterVideo, defaultValue: false)
    static var directlyEnterVideo: Bool

    /// 画质上限。默认放开到杜比视界, 让起播能选到杜比视界/HDR;
    /// 该视频没有 HDR 时按最高分辨率档位选择, 完全没有高档位则落到该视频的最高档
    @UserDefaultCodable(.mediaQuality, defaultValue: .quality_hdr_dolby)
    static var mediaQuality: MediaQualityEnum

    @UserDefaultCodable(.mediaPlayerSpeed, defaultValue: PlaySpeed.default)
    static var mediaPlayerSpeed: PlaySpeed

    @UserDefaultCodable(.danmakuArea, defaultValue: .style_75)
    static var danmakuArea: DanmakuArea

    @UserDefaultCodable(.danmakuSize, defaultValue: .size_36)
    static var danmakuSize: DanmakuSize

    @UserDefaultCodable(.danmakuAILevel, defaultValue: 1)
    static var danmakuAILevel: Int32

    @UserDefaultCodable(.danmakuDuration, defaultValue: 8)
    static var danmakuDuration: Double

    @UserDefault(.losslessAudio, defaultValue: true)
    static var losslessAudio: Bool

    /// AVC 优先。默认开启: 同一画质档位有 AVC 时不用 HEVC (该档位只有 HEVC 时仍会回退)
    @UserDefault(.preferAvc, defaultValue: true)
    static var preferAvc: Bool

    /// 多 CDN 并发加速（默认关）。开启后点播走本地代理，多 CDN 并发 Range 下载聚合带宽。
    @UserDefault(.multiCDNEnabled, defaultValue: false)
    static var multiCDNEnabled: Bool

    @UserDefault(.danmakuMask, defaultValue: true)
    static var danmakuMask: Bool

    /// 上次在播放器字幕菜单里选过的轨道 lan; 空 = 从未选过 / 已手动关闭。
    /// 只表示"记住用户的选择", 是否在起播时自动挂上由 subtitleAutoSelect 决定
    @UserDefault(.subtitlePreferLan, defaultValue: "")
    static var subtitlePreferLan: String

    /// 起播是否自动挂上 subtitlePreferLan 指定的字幕轨道。默认关。
    ///
    /// 为什么要单独一个键: 老版本把 subtitlePreferLan 的默认值写成 "ai-zh" 并且已经落盘,
    /// 而 `@UserDefault` 的 defaultValue 只对"键不存在"生效 —— 光改 default 对已安装用户
    /// 完全无效, 旧值一直赢, 表现就是"什么都没操作, 字幕自己跳出来"。
    /// 用独立开关表达"用户是否真的要自动字幕": 老用户设备上此键不存在 → 默认关 →
    /// 历史遗留偏好被自然中和; 想要字幕的人在播放器菜单里选一次即可(会写回 true)。
    @UserDefault(.subtitleAutoSelect, defaultValue: false)
    static var subtitleAutoSelect: Bool

    @UserDefault(.vnMask, defaultValue: false)
    static var vnMask: Bool

    @UserDefault(.contentMatch, defaultValue: true)
    static var contentMatch: Bool

    @UserDefault(.contentMatchOnlyInHDR, defaultValue: true)
    static var contentMatchOnlyInHDR: Bool

    @UserDefault(.continuePlay, defaultValue: true)
    static var continuePlay: Bool

    @UserDefault(.dlnaUUID, defaultValue: "")
    static var uuid: String

    /// 本地自定义弹幕屏蔽词（关键字匹配，与云端规则共用「用户自定义弹幕屏蔽」开关）
    @UserDefaultCodable(.localDanmakuFilters, defaultValue: [])
    static var localDanmakuFilters: [String]

    @UserDefault(.dlnaEnable, defaultValue: true)
    static var enableDLNA: Bool

    /// 播放结束后自动连播下一条
    @UserDefault(.continuouslyPlay, defaultValue: true)
    static var continuouslyPlay: Bool

    @UserDefault(.loopPlay, defaultValue: false)
    static var loopPlay: Bool

    @UserDefault(.autoSkip, defaultValue: true)
    static var autoSkip: Bool

    /// 用户自记片头标记的自动跳过开关（与 B 站官方片头片尾的 Settings.autoSkip 互不影响）
    @UserDefault(.skipIntroAutoEnabled, defaultValue: true)
    static var skipIntroAutoEnabled: Bool

    /// 用户自记片尾标记的自动跳过开关（与片头独立）
    @UserDefault(.skipOutroAutoEnabled, defaultValue: true)
    static var skipOutroAutoEnabled: Bool

    @UserDefault(.showRelatedVideoInCurrentVC, defaultValue: true)
    static var showRelatedVideoInCurrentVC: Bool

    @UserDefault(.requestHotWithoutCookie, defaultValue: false)
    static var requestHotWithoutCookie: Bool

    @UserDefault(.areaLimitUnlock, defaultValue: false)
    static var areaLimitUnlock: Bool

    @UserDefault(.areaLimitCustomServer, defaultValue: "")
    static var areaLimitCustomServer: String

    @UserDefault(.sideMenuAutoSelectChange, defaultValue: false)
    static var sideMenuAutoSelectChange: Bool

    @UserDefaultCodable(.featuredDurationLimit, defaultValue: .minutes10)
    static var featuredDurationLimit: FeaturedDurationLimit

    @UserDefault(.recommendFeedFlowEnabled, defaultValue: false)
    static var recommendFeedFlowEnabled: Bool

    @UserDefault(.featuredContentSafetyFilterEnabled, defaultValue: true)
    static var featuredContentSafetyFilterEnabled: Bool

    @UserDefault(.followsFeedFlowEnabled, defaultValue: false)
    static var followsFeedFlowEnabled: Bool

    // 默认关闭：开启后会向第三方 bsbsb.top 发送视频 ID 的哈希前缀，需用户主动选择
    @UserDefaultCodable(.enableSponsorBlock, defaultValue: SponsorBlockType.none)
    static var enableSponsorBlock: SponsorBlockType

    @UserDefault(.enableDanmakuFilter, defaultValue: true)
    static var enableDanmakuFilter: Bool

    @UserDefault(.enableDanmakuRemoveDup, defaultValue: false)
    static var enableDanmakuRemoveDup: Bool

    /// pakku 式重复弹幕合并：同文本 + 时间相邻的多条折叠为一条并标注 ×N。默认开。
    /// 开启时优先于「移除重复弹幕」——重复内容折叠成 ×N 比直接抹掉更符合直觉。
    @UserDefault(.danmakuMergeDuplicates, defaultValue: true)
    static var danmakuMergeDuplicates: Bool

    @UserDefaultCodable(.topShelfSource, defaultValue: .all)
    static var topShelfSource: TopShelfSource

    @UserDefaultCodable(.danmakuAlpha, defaultValue: .alpha_10)
    static var danmakuAlpha: DanmakuAlpha

    @UserDefaultCodable(.danmakuStrokeWidth, defaultValue: .width_20)
    static var danmakuStrokeWidth: DanmakuStrokeWidth

    @UserDefaultCodable(.danmakuStrokeAlpha, defaultValue: .alpha_08)
    static var danmakuStrokeAlpha: DanmakuStrokeAlpha

    @UserDefaultCodable(.searchHistories, defaultValue: [])
    static var searchHistories: [String]
}

extension Settings {
    static func addHistory(_ query: String, limitSize: Int = 6) {
        if query.isEmpty {
            return
        }

        var histories = Settings.searchHistories
        if histories.first == query {
            return
        }

        if let i = histories.firstIndex(of: query) {
            histories.remove(at: i)
        }

        histories.insert(query, at: 0)
        if histories.count > limitSize {
            histories.removeLast()
        }
        Settings.searchHistories = histories
    }

    static func clearHistory() {
        Settings.searchHistories = []
    }
}

enum TopShelfSource: String, Codable, CaseIterable {
    case all
    case history
    case toView
    case dynamic
    case continueAndToView
    case allWithHistory
    case off

    var title: String {
        switch self {
        case .all:
            return "动态+稍后再看"
        case .history:
            return "仅继续观看"
        case .toView:
            return "仅稍后再看"
        case .dynamic:
            return "仅动态"
        case .continueAndToView:
            return "继续观看+稍后再看"
        case .allWithHistory:
            return "继续观看+动态+稍后再看"
        case .off:
            return "关闭"
        }
    }

    /// 各档位要拉取的分区，避免刷新逻辑里散落一堆 || 判断
    var sections: Set<TopShelfSection> {
        switch self {
        case .all: return [.toView, .dynamic]
        case .history: return [.history]
        case .toView: return [.toView]
        case .dynamic: return [.dynamic]
        case .continueAndToView: return [.history, .toView]
        case .allWithHistory: return [.history, .toView, .dynamic]
        case .off: return []
        }
    }
}

enum TopShelfSection: Hashable {
    case history
    case toView
    case dynamic
}

enum SponsorBlockType: String, Codable, CaseIterable {
    case none
    case jump
    case tip

    var title: String {
        switch self {
        case .none:
            return "关"
        case .jump:
            return "自动跳过"
        case .tip:
            return "手动跳过"
        }
    }
}

enum DanmakuArea: Codable, CaseIterable {
    case style_75
    case style_50
    case style_25
    case style_0
}

enum DanmakuSize: String, Codable, CaseIterable {
    case size_25
    case size_31
    case size_36
    case size_42
    case size_48
    case size_57

    var title: String {
        return "\(Int(size)) pt"
    }

    var size: CGFloat {
        switch self {
        case .size_25:
            return 25
        case .size_31:
            return 31
        case .size_36:
            return 36
        case .size_42:
            return 42
        case .size_48:
            return 48
        case .size_57:
            return 57
        }
    }
}

/// 「档位滑杆」枚举的公共形状（透明度 / 描边宽度 / 描边透明度）：
/// 数值集合各自定义，title 的展示格式统一从这里出，避免三份一样的实现随时间漂移
/// （审核 2026-10-20 问题 16；rawValue 数值与 Codable 落盘格式保持不变）
protocol DanmakuSliderLevel: RawRepresentable, CaseIterable where RawValue == Double {}

extension DanmakuSliderLevel {
    var title: String { String(format: "%.1f", rawValue) }
}

enum DanmakuAlpha: Double, Codable, CaseIterable, DanmakuSliderLevel {
    case alpha_03 = 0.3
    case alpha_04 = 0.4
    case alpha_05 = 0.5
    case alpha_06 = 0.6
    case alpha_07 = 0.7
    case alpha_08 = 0.8
    case alpha_09 = 0.9
    case alpha_10 = 1.0
}

enum DanmakuStrokeWidth: Double, Codable, CaseIterable, DanmakuSliderLevel {
    case width_0 = 0.0
    case width_05 = 0.5
    case width_10 = 1.0
    case width_15 = 1.5
    case width_20 = 2.0
}

enum DanmakuStrokeAlpha: Double, Codable, CaseIterable, DanmakuSliderLevel {
    case alpha_00 = 0.0
    case alpha_01 = 0.1
    case alpha_02 = 0.2
    case alpha_03 = 0.3
    case alpha_04 = 0.4
    case alpha_05 = 0.5
    case alpha_06 = 0.6
    case alpha_07 = 0.7
    case alpha_08 = 0.8
    case alpha_09 = 0.9
    case alpha_10 = 1.0
}

extension DanmakuArea {
    var title: String {
        switch self {
        case .style_75:
            return "3/4屏"
        case .style_50:
            return "半屏"
        case .style_25:
            return "1/4屏"
        case .style_0:
            return "不限制"
        }
    }

    var percent: CGFloat {
        switch self {
        case .style_75:
            return 0.75
        case .style_50:
            return 0.5
        case .style_25:
            return 0.25
        case .style_0:
            return 1
        }
    }
}

enum FeaturedDurationLimit: Codable, CaseIterable, Equatable {
    case minutes3
    case minutes5
    case minutes10
    case minutes15
    case unlimited
}

extension FeaturedDurationLimit {
    var title: String {
        switch self {
        case .minutes3:
            return "3 分钟"
        case .minutes5:
            return "5 分钟"
        case .minutes10:
            return "10 分钟"
        case .minutes15:
            return "15 分钟"
        case .unlimited:
            return "不限"
        }
    }

    var maxDuration: Int? {
        switch self {
        case .minutes3:
            return 3 * 60
        case .minutes5:
            return 5 * 60
        case .minutes10:
            return 10 * 60
        case .minutes15:
            return 15 * 60
        case .unlimited:
            return nil
        }
    }
}

enum MediaQualityEnum: Codable, CaseIterable {
    case quality_1080p
    case quality_2160p
    case quality_hdr_dolby
}

/// B 站画质档位号 (qn)。集中一处声明，避免散落硬编码后与枚举脱节
/// （原先 `isHDR10` 直接写 `id == 125`，而 `MediaQualityEnum` 里根本没有 HDR case）。
/// HDR10(125) / 杜比视界(126) 不是可选的"最高画质"档位，只用于识别取到的流，故不进枚举。
enum QualityId {
    static let hd1080p = 116
    static let uhd4k = 120
    static let hdr10 = 125
    static let dolbyVision = 126
}

extension MediaQualityEnum {
    var desp: String {
        switch self {
        case .quality_1080p:
            return "1080p"
        case .quality_2160p:
            return "4K"
        case .quality_hdr_dolby:
            return "杜比视界"
        }
    }

    var qn: Int {
        switch self {
        case .quality_1080p:
            return QualityId.hd1080p
        case .quality_2160p:
            return QualityId.uhd4k
        case .quality_hdr_dolby:
            return QualityId.dolbyVision
        }
    }

    var fnval: Int {
        switch self {
        case .quality_1080p:
            return 16
        case .quality_2160p:
            return 144
        case .quality_hdr_dolby:
            return 976
        }
    }
}
