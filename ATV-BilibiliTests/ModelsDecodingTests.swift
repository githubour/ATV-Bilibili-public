//
//  ModelsDecodingTests.swift
//  ATV-BilibiliTests
//

@testable import ATV_Bilibili
import XCTest

/// 模型解码回归网：批次 3 搬运 Codable 模型、批次 5 改类型名时，
/// 这些最小 JSON 用例守住「能解码 + 关键字段值正确」。只断言字段值，
/// 不断言 Hashable 的 hash 值、不依赖键序、不 mock 网络。
final class ModelsDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()

    func test_videoDetail_decodes() throws {
        let json = """
        {"View":{"aid":42,"cid":242,"title":"测试视频","duration":300,
                 "owner":{"mid":7,"name":"UP主","face":"https://i0.hdslb.com/f.jpg"},
                 "stat":{"favorite":1,"coin":2,"like":3,"share":4,"danmaku":5,"view":6}},
         "Related":[],
         "Card":{"following":false,"follower":10}}
        """
        let detail = try decoder.decode(VideoDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.View.aid, 42)
        XCTAssertEqual(detail.View.cid, 242)
        XCTAssertEqual(detail.View.title, "测试视频")
        XCTAssertEqual(detail.View.stat.view, 6)
        // DisplayData 映射仍可用（批次 3 会搬运这些 extension）
        let asDisplay: any DisplayData = detail
        XCTAssertEqual(asDisplay.title, "测试视频")
        XCTAssertEqual(asDisplay.ownerName, "UP主")
        // PlayableData 所需的 aid/cid 仍可取
        let info = detail.View
        XCTAssertEqual(info.aid, 42)
    }

    func test_playerInfo_decodes() throws {
        let json = #"{"last_play_time":90000,"last_play_cid":242}"#
        let info = try decoder.decode(PlayerInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.last_play_time, 90000)
        XCTAssertEqual(info.last_play_cid, 242)
        // 计算属性：毫秒 → 秒
        XCTAssertEqual(info.playTimeInSecond, 90)
    }

    func test_videoPlayURLInfo_dashMediaInfo_decodes() throws {
        let json = """
        {"quality":116,"format":"dash","timelength":60000,"accept_format":"dash",
         "accept_description":["高清 1080P60"],"accept_quality":[116],"video_codecid":7,
         "support_formats":[{"quality":116,"format":"dash","new_description":"高清 1080P60","display_desc":"1080P60"}],
         "dash":{"duration":60000,"minBufferTime":1.5,
                 "video":[
                   {"id":116,"base_url":"https://cdn.example.com/v.m4s","backup_url":["https://cdn2.example.com/v.m4s"],
                    "bandwidth":2000000,"mime_type":"video/mp4","codecs":"avc1.640034","width":1920,"height":1080,
                    "frame_rate":"16000/672","sar":"1:1","start_with_sap":1,
                    "segment_base":{"initialization":"0-999","index_range":"1000-1999"},"codecid":7},
                   {"id":125,"base_url":"https://cdn.example.com/h.m4s","backup_url":null,
                    "bandwidth":3000000,"mime_type":"video/mp4","codecs":"hev1.1.6.L120.90","width":1920,"height":1080,
                    "frame_rate":"16000/672","sar":"1:1","start_with_sap":1,
                    "segment_base":{"initialization":"0-999","index_range":"1000-1999"},"codecid":12}]}
        }
        """
        let info = try decoder.decode(VideoPlayURLInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.dash.video.count, 2)
        // 选流域的三个 extension 属性仍可用（会被搬进 BVideoStreamSelection.swift 域）
        let avcStream = info.dash.video[0]
        XCTAssertFalse(avcStream.isHevc)
        XCTAssertEqual(avcStream.dynamicRangeRank, 0)
        XCTAssertEqual(avcStream.playableURLs, ["https://cdn.example.com/v.m4s", "https://cdn2.example.com/v.m4s"])
        let hevcStream = info.dash.video[1]
        XCTAssertTrue(hevcStream.isHevc)
        XCTAssertEqual(hevcStream.dynamicRangeRank, 1)
        XCTAssertEqual(hevcStream.playableURLs.count, 1)
    }

    func test_bangumiSeasonInfo_decodes() throws {
        let json = """
        {"main_section":{"type":1,"season_id":999,
                         "episodes":[{"id":1001,"aid":42,"cid":242,"cover":"https://i0.hdslb.com/c.jpg",
                                      "title":"第1话","long_title":"序章"}]},
         "section":[]}
        """
        let season = try decoder.decode(BangumiSeasonInfo.self, from: Data(json.utf8))
        XCTAssertEqual(season.main_section.season_id, 999)
        XCTAssertEqual(season.main_section.episodes.count, 1)
        XCTAssertEqual(season.main_section.episodes[0].long_title, "序章")
        XCTAssertEqual(season.main_section.findEpisodeById(1001)?.aid, 42)
    }

    func test_replys_decodes() throws {
        let json = """
        {"replies":[{"member":{"uname":"user","avatar":"https://i0.hdslb.com/a.jpg"},
                     "content":{"message":"你好",
                                "pictures":[{"img_src":"https://i0.hdslb.com/p.jpg"}],
                                "emote":{},"jump_url":{}},
                     "replies":[]}]}
        """
        let replys = try decoder.decode(Replys.self, from: Data(json.utf8))
        XCTAssertEqual(replys.replies?.count, 1)
        XCTAssertEqual(replys.replies?[0].member.uname, "user")
        XCTAssertEqual(replys.replies?[0].content.message, "你好")
        XCTAssertEqual(replys.replies?[0].content.pictures?.count, 1)
    }
}
