//
//  SubtitlePreferenceTests.swift
//  ATV-BilibiliTests
//
//  字幕"起播该不该自动挂上"的判断。这段逻辑被两版代码改错过两次:
//    ① 快进/快退时闪出一句英文字幕(偏好没匹配到时留空, 交给系统自动选)
//    ② 什么都没操作, 字幕在播放时自己跳出来(老版本把 ai-zh 落盘成偏好,
//       光改 defaultValue 对已安装用户无效)
//  两次都源于"让偏好值本身兼任开关"。这里锁定: 只看显式开关 + 会话内手动选择优先。
//

@testable import ATV_Bilibili
import XCTest

final class SubtitlePreferenceTests: XCTestCase {
    // MARK: - 起播(本会话未手动操作)

    /// 核心回归: 设备上残留 "ai-zh" 偏好但开关是关的 → 必须不挂字幕
    func test_boot_leakedLegacyPreference_doesNotAutoSelect() {
        XCTAssertNil(SubtitlePlugin.resolvedPreferenceLane(sessionLan: nil,
                                                           autoSelect: false,
                                                           preferLan: "ai-zh"))
    }

    /// 老用户升级后: 偏好仍是 ai-zh, 但新键不存在 → 默认关 → 不挂字幕
    func test_boot_freshUpgrade_defaultIsOff() {
        XCTAssertNil(SubtitlePlugin.resolvedPreferenceLane(sessionLan: nil,
                                                           autoSelect: false,
                                                           preferLan: ""))
    }

    /// 用户明确在菜单里选过轨道 → 起播沿用
    func test_boot_explicitAutoSelect_usesRememberedLane() {
        XCTAssertEqual(SubtitlePlugin.resolvedPreferenceLane(sessionLan: nil,
                                                             autoSelect: true,
                                                             preferLan: "zh-CN"),
                       "zh-CN")
    }

    /// 开关开着但偏好是空(用户从没选过轨) → 不挂字幕, 不能回退到"随便挑一条"
    func test_boot_autoSelectWithoutLane_selectsNothing() {
        XCTAssertNil(SubtitlePlugin.resolvedPreferenceLane(sessionLan: nil,
                                                           autoSelect: true,
                                                           preferLan: ""))
    }

    // MARK: - 本会话手动操作优先

    /// 本会话手动关闭 → 切集也不许再挂上, 即便开关是开的
    func test_sessionOff_beatsAutoSelect() {
        XCTAssertNil(SubtitlePlugin.resolvedPreferenceLane(sessionLan: "",
                                                           autoSelect: true,
                                                           preferLan: "zh-CN"))
    }

    /// 本会话手动选轨 → 覆盖全局开关(此时开关可能还是关的)
    func test_sessionLane_beatsGlobalSwitch() {
        XCTAssertEqual(SubtitlePlugin.resolvedPreferenceLane(sessionLan: "ai-en",
                                                             autoSelect: false,
                                                             preferLan: ""),
                       "ai-en")
    }

    // MARK: - 内容层：哪些轨道允许有内容（压制 tvOS 暂停/回看时的自动选轨）

    /// 核心回归: 开关关着时，任何轨道都不给内容 ——
    /// 这样系统在暂停/回看时自己挑一条轨也拉不到 cue，字幕无从渲染
    func test_wantedSubtitleLan_offMeansNoContent() {
        XCTAssertNil(BilibiliVideoResourceLoaderDelegate.wantedSubtitleLan(autoSelect: false,
                                                                           preferLan: "ai-zh"))
    }

    func test_wantedSubtitleLan_onReturnsChosenLane() {
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.wantedSubtitleLan(autoSelect: true,
                                                                             preferLan: "zh"),
                       "zh")
    }

    /// 开关开着但没选过具体轨道 → 同样不给内容，不能退化成"随便给一条"
    func test_wantedSubtitleLan_onWithoutLane() {
        XCTAssertNil(BilibiliVideoResourceLoaderDelegate.wantedSubtitleLan(autoSelect: true,
                                                                           preferLan: ""))
    }

    // MARK: - 偏好语言 → 实际轨道 lan（插件选轨与内容层放行必须同一结果）

    func test_resolvedSubtitleLan_exactWins() {
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.resolvedSubtitleLan(
            preference: "zh-CN",
            availableLans: ["ai-zh", "zh-CN"]
        ), "zh-CN")
    }

    /// 旧偏好 ai-zh，视频只有人工 zh-CN：必须解析到 zh-CN，否则插件选中后清单被回空
    func test_resolvedSubtitleLan_fuzzyAIToHuman() {
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.resolvedSubtitleLan(
            preference: "ai-zh",
            availableLans: ["zh-CN", "en-US"]
        ), "zh-CN")
    }

    /// 反向也要成立：偏好 zh-CN，视频只有 AI 中文
    func test_resolvedSubtitleLan_fuzzyHumanToAI() {
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.resolvedSubtitleLan(
            preference: "zh-CN",
            availableLans: ["ai-zh", "en-US"]
        ), "ai-zh")
    }

    func test_resolvedSubtitleLan_noMatch() {
        XCTAssertNil(BilibiliVideoResourceLoaderDelegate.resolvedSubtitleLan(
            preference: "ai-zh",
            availableLans: ["en-US", "ja-JP"]
        ))
    }
}
