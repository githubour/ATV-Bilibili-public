//
//  BVideoStreamSelectionTests.swift
//  ATV-BilibiliTests
//

@testable import ATV_Bilibili
import XCTest

final class BVideoStreamSelectionTests: XCTestCase {
    /// 13 个存储属性的最小工厂：选流只关心 id(画质档)/bandwidth/codecs(编码)
    private func makeStream(id: Int, bandwidth: Int, codecs: String) -> VideoPlayURLInfo.DashInfo.DashMediaInfo {
        .init(id: id, base_url: "https://cdn.example.com/v.m4s", backup_url: nil,
              bandwidth: bandwidth, mime_type: "video/mp4", codecs: codecs,
              width: nil, height: nil, frame_rate: nil, sar: nil, start_with_sap: nil,
              segment_base: .init(initialization: "0-999", index_range: "1000-1999"), codecid: nil)
    }

    private let avc = "avc1.640034"
    private let hevc = "hev1.1.6.L120.90"
    private let dolbyVision = "dvh1.05.06"

    func test_preferringAVC_dropsHEVCWithinSameTier_onlyWhenEnabled() {
        let hevcStream = makeStream(id: 80, bandwidth: 2000, codecs: hevc)
        let avcStream = makeStream(id: 80, bandwidth: 1500, codecs: avc)
        // 同档剔 HEVC，即便它码率更高
        XCTAssertEqual(BVideoStreamSelection.preferringAVC([hevcStream, avcStream], preferAvc: true), [avcStream])
        // 关开关原样返回
        XCTAssertEqual(BVideoStreamSelection.preferringAVC([hevcStream, avcStream], preferAvc: false).count, 2)
        // 该档无 AVC 时保留 HEVC 兜底
        XCTAssertEqual(BVideoStreamSelection.preferringAVC([hevcStream], preferAvc: true), [hevcStream])
    }

    func test_defaultStream_dynamicRangeBeatsQuality() {
        let sdr = makeStream(id: 120, bandwidth: 8000, codecs: avc)
        let hdr = makeStream(id: 125, bandwidth: 3000, codecs: hevc)
        let dolby = makeStream(id: 126, bandwidth: 1000, codecs: dolbyVision)
        // 杜比视界优先于 HDR、HDR 优先于 SDR（即便码率/档位更低）
        XCTAssertEqual(BVideoStreamSelection.defaultStream(from: [sdr, hdr, dolby], preferAvc: true, maxQn: 126), dolby)
        XCTAssertEqual(BVideoStreamSelection.defaultStream(from: [sdr, hdr], preferAvc: true, maxQn: 126), hdr)
        XCTAssertEqual(BVideoStreamSelection.defaultStream(from: [sdr], preferAvc: true, maxQn: 126), sdr)
    }

    func test_defaultStream_sameTierPicksHighestBandwidth() {
        let low = makeStream(id: 80, bandwidth: 1500, codecs: avc)
        let high = makeStream(id: 80, bandwidth: 2000, codecs: avc)
        XCTAssertEqual(BVideoStreamSelection.defaultStream(from: [low, high], preferAvc: true, maxQn: 126), high)
    }

    func test_defaultStream_maxQnFiltersEverything_returnsNil() {
        let sdr = makeStream(id: 120, bandwidth: 8000, codecs: avc)
        let hdr = makeStream(id: 125, bandwidth: 3000, codecs: hevc)
        let dolby = makeStream(id: 126, bandwidth: 1000, codecs: dolbyVision)
        XCTAssertNil(BVideoStreamSelection.defaultStream(from: [sdr, hdr, dolby], preferAvc: true, maxQn: 80))
    }

    func test_defaultStream_hevcOnlyTierKeptAsFallback() {
        let hevcStream = makeStream(id: 80, bandwidth: 2000, codecs: hevc)
        XCTAssertEqual(BVideoStreamSelection.defaultStream(from: [hevcStream], preferAvc: true, maxQn: 126), hevcStream)
    }

    func test_select_manualStreamIndexWins() {
        let first = makeStream(id: 80, bandwidth: 1500, codecs: avc)
        let second = makeStream(id: 64, bandwidth: 9000, codecs: hevc)
        // 手动指定流原样返回，不做 AVC/画质处理
        XCTAssertEqual(
            BVideoStreamSelection.select(videos: [first, second], streamIndex: 1, maxQuality: nil,
                                         preferAvc: true, maxQn: 126),
            [second]
        )
    }

    func test_select_streamIndexOutOfRangeFallsThrough() {
        let sdr = makeStream(id: 120, bandwidth: 8000, codecs: avc)
        // 越界下标落到 maxQuality/defaultStream 分支，而不是返回空
        XCTAssertEqual(
            BVideoStreamSelection.select(videos: [sdr], streamIndex: 9, maxQuality: nil,
                                         preferAvc: true, maxQn: 126),
            [sdr]
        )
    }

    func test_select_maxQualityPicksTierBest() {
        let low = makeStream(id: 64, bandwidth: 1000, codecs: avc)
        let high = makeStream(id: 64, bandwidth: 2000, codecs: avc)
        let other = makeStream(id: 80, bandwidth: 9000, codecs: avc)
        XCTAssertEqual(
            BVideoStreamSelection.select(videos: [low, high, other], streamIndex: nil, maxQuality: 64,
                                         preferAvc: true, maxQn: 126),
            [high]
        )
    }

    func test_select_maxQualityWithNoMatchingTierReturnsEmpty() {
        let other = makeStream(id: 80, bandwidth: 9000, codecs: avc)
        // 既定行为：指定画质档不存在 → 空数组（不退回兜底）
        XCTAssertEqual(
            BVideoStreamSelection.select(videos: [other], streamIndex: nil, maxQuality: 64,
                                         preferAvc: true, maxQn: 126),
            []
        )
    }

    func test_select_defaultFallbackNeverEmpty_whenMaxQualityIsNil() {
        let dolby = makeStream(id: 126, bandwidth: 1000, codecs: dolbyVision)
        // 仅当 maxQuality == nil 且 defaultStream 被 maxQn 全滤掉时，退回 preferringAVC 且非空
        XCTAssertEqual(
            BVideoStreamSelection.select(videos: [dolby], streamIndex: nil, maxQuality: nil,
                                         preferAvc: true, maxQn: 80),
            [dolby]
        )
    }
}
