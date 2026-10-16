//
//  SkipMarkersTests.swift
//  ATV-BilibiliTests
//

@testable import ATV_Bilibili
import XCTest

final class SkipMarkersTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suite = "test.skipmarkers.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite) else {
            XCTFail("无法创建测试 suite: \(suite)")
            return
        }
        suiteName = suite
        defaults = store
        SkipMarkerStore.storage = store
        addTeardownBlock {
            store.removePersistentDomain(forName: suite)
            SkipMarkerStore.storage = .standard
        }
    }

    // MARK: - key(for:)

    func test_key_bangumiVsNormal() {
        // 番剧按 season 记忆
        XCTAssertEqual(SkipMarkerStore.key(for: PlayInfo(aid: 42, seasonId: 999)), "season-999")
        // seasonId 缺省 0 视为普通视频，按 aid 记忆
        XCTAssertEqual(SkipMarkerStore.key(for: PlayInfo(aid: 42)), "aid-42")
        XCTAssertEqual(SkipMarkerStore.key(for: PlayInfo(aid: 42, seasonId: 0)), "aid-42")
    }

    // MARK: - resolveMarkers（跨集换算）

    private func markers(outro: Double, recordedDuration: Double?) -> SkipMarkers {
        SkipMarkers(introSeconds: nil, outroSeconds: outro, outroDuration: recordedDuration)
    }

    func test_resolveMarkers_outroCrossEpisode_byEdLength() {
        // 记录片长 1440（ED 起点 1300 → ED 长 140s），当前片长 1560 相差 120s > 容差 20s
        // → 按 ED 长度换算：1560 - 140 = 1420
        let resolved = SkipMarkerResolver.resolveMarkers(markers(outro: 1300, recordedDuration: 1440), duration: 1560)
        XCTAssertEqual(resolved.outroSeconds, 1420)
    }

    func test_resolveMarkers_outroSameDuration_fallsBackToAbsolute() {
        // 片长一致（差 0 ≤ 20s）→ 退回绝对时刻
        let resolved = SkipMarkerResolver.resolveMarkers(markers(outro: 1300, recordedDuration: 1440), duration: 1440)
        XCTAssertEqual(resolved.outroSeconds, 1300)
    }

    func test_resolveMarkers_noRecordedDuration_fallsBackToAbsolute() {
        let resolved = SkipMarkerResolver.resolveMarkers(markers(outro: 1300, recordedDuration: nil), duration: 1560)
        XCTAssertEqual(resolved.outroSeconds, 1300)
    }

    func test_resolveMarkers_edLengthNotLessThanCurrent_becomesNil() {
        // ED 长度 >= 当前片长（数据不合理）→ 置 nil，不自动跳
        let resolved = SkipMarkerResolver.resolveMarkers(markers(outro: 100, recordedDuration: 2000), duration: 300)
        XCTAssertNil(resolved.outroSeconds)
    }

    func test_resolveMarkers_negativeEdLength_becomesNil() {
        // 记录片长比标记时刻还短（ED 长度为负）→ 置 nil
        let resolved = SkipMarkerResolver.resolveMarkers(markers(outro: 1300, recordedDuration: 1200), duration: 2000)
        XCTAssertNil(resolved.outroSeconds)
    }

    func test_resolveMarkers_introPassesThrough() {
        // 片头是绝对秒，任何 duration 下原样沿用
        let stored = SkipMarkers(introSeconds: 45, outroSeconds: nil, outroDuration: nil)
        XCTAssertEqual(SkipMarkerResolver.resolveMarkers(stored, duration: 999).introSeconds, 45)
    }

    func test_resolveMarkers_tolerancesBoundary() {
        // 容差边界：相差恰好 20s 视为接近 → 绝对时刻
        let resolved = SkipMarkerResolver.resolveMarkers(markers(outro: 1300, recordedDuration: 1440), duration: 1460)
        XCTAssertEqual(resolved.outroSeconds, 1300)
    }

    // MARK: - store 往返

    func test_store_roundtrip() {
        let normal = PlayInfo(aid: 42)
        SkipMarkerStore.setIntro(45, for: normal)
        SkipMarkerStore.setOutro(1300, duration: 1440, for: normal)
        let markers = SkipMarkerStore.markers(for: normal)
        XCTAssertEqual(markers.introSeconds, 45)
        XCTAssertEqual(markers.outroSeconds, 1300)
        XCTAssertEqual(markers.outroDuration, 1440)

        // 清除片尾：outroSeconds 与 outroDuration 同时归 nil
        SkipMarkerStore.setOutro(nil, duration: 1440, for: normal)
        let cleared = SkipMarkerStore.markers(for: normal)
        XCTAssertNil(cleared.outroSeconds)
        XCTAssertNil(cleared.outroDuration)

        // 同一季的番剧共享同一组标记
        let bangumi = PlayInfo(aid: 42, seasonId: 999)
        SkipMarkerStore.setIntro(30, for: bangumi)
        XCTAssertEqual(SkipMarkerStore.markers(for: PlayInfo(aid: 42, seasonId: 999)).introSeconds, 30)
        // 普通视频与番剧互不串扰
        XCTAssertEqual(SkipMarkerStore.markers(for: PlayInfo(aid: 42)).introSeconds, 45)
    }
}
