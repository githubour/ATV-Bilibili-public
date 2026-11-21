//
//  ToViewCleanupTests.swift
//  ATV-BilibiliTests
//
//  「移除已播放」的口径：只清即将播完的，看了一部分的必须保留。
//  服务端 viewed=true 只认「播过」，所以判定在本地做，这里守住这套判定。
//

@testable import ATV_Bilibili
import XCTest

final class ToViewCleanupTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func makeItem(progress: Int?, duration: Int, cid: Int = 100, pages: [ToViewData.Page]? = nil) -> ToViewData {
        ToViewData(title: "测试",
                   cid: cid,
                   aid: 1,
                   owner: VideoOwner(mid: 1, name: "UP", face: nil),
                   pic: nil,
                   pubdate: 0,
                   duration: duration,
                   progress: progress,
                   pages: pages,
                   stat: nil)
    }

    // MARK: - 判定

    func test_barelyWatched_isKept() {
        // 600 秒的视频只看了 30 秒 —— 正是这次要修掉的误删场景
        XCTAssertFalse(makeItem(progress: 30, duration: 600).isNearlyFinished)
    }

    func test_nearTheEnd_isRemoved() {
        XCTAssertTrue(makeItem(progress: 570, duration: 600).isNearlyFinished)
        XCTAssertTrue(makeItem(progress: 600, duration: 600).isNearlyFinished)
        XCTAssertFalse(makeItem(progress: 564, duration: 600).isNearlyFinished)
    }

    /// 服务端用 -1 标记已看完
    func test_finishedMarkedWithMinusOne_isRemoved() {
        XCTAssertTrue(makeItem(progress: -1, duration: 600).isNearlyFinished)
    }

    func test_neverPlayed_isKept() {
        XCTAssertFalse(makeItem(progress: nil, duration: 600).isNearlyFinished)
        XCTAssertFalse(makeItem(progress: 0, duration: 600).isNearlyFinished)
    }

    /// 时长未知时不能凭 progress 猜，宁可留着让用户手动删
    func test_unknownDuration_isKept() {
        XCTAssertFalse(makeItem(progress: 300, duration: 0).isNearlyFinished)
    }

    /// 多 P 稿件：duration 是全 P 总和，progress 是当前这一 P 的进度，
    /// 必须按 cid 命中当前 P 的时长算，否则进度会被算小、永远清不掉
    func test_multiPart_usesCurrentPartDuration() {
        // 当前在看的第 2P 只有 300 秒，已看 290 秒；总时长 1200 秒只是干扰项
        let pages = [ToViewData.Page(cid: 100, duration: 900), ToViewData.Page(cid: 101, duration: 300)]
        let item = makeItem(progress: 290, duration: 1200, cid: 101, pages: pages)
        XCTAssertTrue(item.isNearlyFinished)
    }

    /// 老响应不带 pages 时只能退回总时长：进度算小 → 不删（安全方向）
    func test_multiPartWithoutPages_isKept() {
        let item = makeItem(progress: 290, duration: 1200)
        XCTAssertFalse(item.isNearlyFinished)
    }

    // MARK: - 解码

    func test_decodesProgressAndPages() throws {
        let json = #"""
        {"list":[{"title":"多P","cid":101,"aid":42,
                  "owner":{"mid":7,"name":"UP","face":null},
                  "pic":"https://i0.hdslb.com/a.jpg","pubdate":1700000000,
                  "duration":1200,"progress":290,
                  "pages":[{"cid":100,"duration":900},{"cid":101,"duration":300}],
                  "stat":{"view":10,"danmaku":2}}]}
        """#
        struct Resp: Codable { let list: [ToViewData] }
        let resp = try decoder.decode(Resp.self, from: Data(json.utf8))
        let item = try XCTUnwrap(resp.list.first)
        XCTAssertEqual(item.progress, 290)
        XCTAssertEqual(item.pages?.count, 2)
        XCTAssertTrue(item.isNearlyFinished)
    }

    /// 缺 progress / pages 的老响应仍要能解码（否则整页拉不出来）
    func test_decodesWithoutProgressAndPages() throws {
        let json = #"""
        {"title":"单P","cid":100,"aid":42,
         "owner":{"mid":7,"name":"UP","face":null},
         "pic":null,"pubdate":1700000000,"duration":600}
        """#
        let item = try decoder.decode(ToViewData.self, from: Data(json.utf8))
        XCTAssertNil(item.progress)
        XCTAssertNil(item.pages)
        XCTAssertFalse(item.isNearlyFinished)
    }
}
