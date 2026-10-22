//
//  PlayContextCacheTests.swift
//  ATV-BilibiliTests
//

@testable import ATV_Bilibili
import XCTest

/// 缓存时效回归：playurl 是带签名的有时效地址，命中过期快照会导致播放失败，
/// 因此「什么时候算过期」必须是可独立验证的纯判断。
final class PlayContextCacheTests: XCTestCase {
    private let maxAge: TimeInterval = 20 * 60

    private func makeSnapshot(createdAt: Date) throws -> PlayContextSnapshot {
        let json = """
        {"quality":116,"format":"dash","timelength":60000,"accept_format":"dash",
         "accept_description":["高清 1080P60"],"accept_quality":[116],"video_codecid":7,
         "support_formats":[{"quality":116,"format":"dash","new_description":"高清 1080P60","display_desc":"1080P60"}],
         "dash":{"duration":60000,"minBufferTime":1.5,
                 "video":[
                   {"id":116,"base_url":"https://cdn.example.com/v.m4s","backup_url":null,
                    "bandwidth":2000000,"mime_type":"video/mp4","codecs":"avc1.640034","width":1920,"height":1080,
                    "frame_rate":"16000/672","sar":"1:1","start_with_sap":1,
                    "segment_base":{"initialization":"0-999","index_range":"1000-1999"},"codecid":7}]}
        }
        """
        let urlInfo = try JSONDecoder().decode(VideoPlayURLInfo.self, from: Data(json.utf8))
        return PlayContextSnapshot(cid: 242, playerInfo: nil, videoPlayURLInfo: urlInfo, detail: nil, createdAt: createdAt)
    }

    func test_freshSnapshotIsNotStale() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try makeSnapshot(createdAt: created)
        XCTAssertFalse(snapshot.isStale(now: created.addingTimeInterval(maxAge - 1), maxAge: maxAge))
    }

    /// 边界：恰好等于有效期仍按可用处理，超过才算过期
    func test_staleBoundary() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try makeSnapshot(createdAt: created)
        XCTAssertFalse(snapshot.isStale(now: created.addingTimeInterval(maxAge), maxAge: maxAge))
        XCTAssertTrue(snapshot.isStale(now: created.addingTimeInterval(maxAge + 1), maxAge: maxAge))
    }

    /// 未来时间戳（客户端时钟回拨）不应被判过期而反复重新取流
    func test_futureTimestampIsNotStale() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try makeSnapshot(createdAt: created.addingTimeInterval(3600))
        XCTAssertFalse(snapshot.isStale(now: created, maxAge: maxAge))
    }
}
