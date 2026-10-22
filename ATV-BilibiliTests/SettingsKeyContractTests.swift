//
//  SettingsKeyContractTests.swift
//  ATV-BilibiliTests
//

@testable import ATV_Bilibili
import XCTest

/// 存储契约冻结测试：这些 rawValue 字符串是用户设备上的持久化 key，
/// 任何改名/丢失都会让全体用户设置静默归零。改名 SettingsKey case 前后本测试必须全绿。
/// 断言的是「存储契约」而非 Swift 标识符——case 名可以改，rawValue 一个字都不能动。
final class SettingsKeyContractTests: XCTestCase {
    private static let frozenKeys: [String] = [
        "Settings.danmuStatus", "Settings.displayStyle", "Settings.direatlyEnterVideo",
        "Settings.mediaQuality", "Settings.mediaPlayerSpeed", "Settings.danmuArea",
        "Settings.danmuSize", "Settings.danmuAILevel", "Settings.danmuDuration",
        "Settings.losslessAudio", "Settings.preferAvc", "Settings.danmuMask",
        "Settings.subtitlePreferLan", "Settings.subtitleAutoSelect", "Settings.vnMask", "Settings.contentMatch",
        "Settings.contentMatchOnlyInHDR", "Settings.continuePlay",
        "DLNA.uuid", "DLNA.enable",
        "Settings.continouslyPlay", // rawValue 里的历史拼写错误必须永久保留
        "Settings.loopPlay", "Settings.play.autoSkip",
        "Settings.play.skipIntroAutoEnabled", "Settings.play.skipOutroAutoEnabled",
        "Settings.skipMarkers.byKey", "Settings.showRelatedVideoInCurrentVC",
        "Settings.requestHotWithoutCookie", "Settings.arealimit.unlock",
        "Settings.arealimit.customServer", "Settings.ui.sideMenuAutoSelectChange",
        "Settings.featuredDurationLimit", "Settings.recommendFeedFlowEnabled",
        "Settings.featuredContentSafetyFilterEnabled", "Settings.followsFeedFlowEnabled",
        "Settings.SponsorBlockType", "Settings.danmuFilter", "Settings.danmuRemoveDup",
        "Settings.danmuMergeDup",
        "Settings.topShelfSource", "Settings.danmuAlpha", "Settings.danmuStrokeWidth",
        "Settings.danmuStrokeAlpha", "Search.histories", "Settings.tabBarPagePlacements",
        "Settings.tabBarPlacement.favoriteToPersonalMigrated",
        "VideoDanmuFilter.filters", "VideoDanmuFilter.localFilters", "VideoDanmuFilter.lastUpdate",
        "Settings.multiCDNEnabled",
    ]

    func test_settingsKeyRawValuesAreFrozen() {
        XCTAssertEqual(Self.frozenKeys.count, Set(Self.frozenKeys).count, "清单内自身有重复，先修测试")
        for raw in Self.frozenKeys {
            XCTAssertNotNil(SettingsKey(rawValue: raw), "存储 key 丢失: \(raw) —— 用户设置会被重置!")
        }
    }

    /// 反向守护：双向集合相等，同时拦住四类静默错误——
    /// ① key 被删 ② 新增未登记的 key ③ rawValue 被改 ④ 两个 case 写了同一个 rawValue
    func test_settingsKeyCasesMatchFrozenListExactly() {
        let actual = Set(SettingsKey.allCases.map(\.rawValue))
        let frozen = Set(Self.frozenKeys)
        XCTAssertEqual(actual, frozen,
                       "SettingsKey 与冻结清单不一致。多出: \(actual.subtracting(frozen).sorted())；缺失: \(frozen.subtracting(actual).sorted())")
    }
}
