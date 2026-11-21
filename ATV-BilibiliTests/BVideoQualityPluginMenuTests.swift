//
//  BVideoQualityPluginMenuTests.swift
//  ATV-BilibiliTests
//
//  审核行动项 #8：画质菜单按 id 分组构建的回归测试——
//  强解包改空数组兜底后，分组、排序与单流/多流命名必须保持原行为。
//

@testable import ATV_Bilibili
import XCTest

final class BVideoQualityPluginMenuTests: XCTestCase {
    /// 与 PlayContextCacheTests 同款的最小 VideoPlayURLInfo JSON：
    /// 116 档两条流（AVC + HEVC，验证同档分组）+ 80 档一条流（验证单流命名）
    private func makeURLInfoJSON(videoStreams: String) -> String {
        """
        {"quality":116,"format":"dash","timelength":60000,"accept_format":"dash",
         "accept_description":["高清 1080P60"],"accept_quality":[116],"video_codecid":7,
         "support_formats":[
           {"quality":116,"format":"dash","new_description":"高清 1080P60","display_desc":"1080P60"},
           {"quality":80,"format":"dash","new_description":"高清 720P","display_desc":"720P"}],
         "dash":{"duration":60000,"minBufferTime":1.5,
                 "video":[\(videoStreams)]}
        }
        """
    }

    private func makePlugin(json: String) throws -> BVideoQualityPlugin {
        let urlInfo = try JSONDecoder().decode(VideoPlayURLInfo.self, from: Data(json.utf8))
        let detailData = PlayerDetailData(
            aid: 1, cid: 2, epid: nil, seasonId: nil, subType: nil,
            playerStartPos: nil, detail: nil, clips: nil, playerInfo: nil,
            videoPlayURLInfo: urlInfo
        )
        return BVideoQualityPlugin(detailData: detailData) { _, _ in true }
    }

    func test_groupByQuality_sortedDesc_singleStreamTitleKeepsBandwidth() throws {
        let plugin = try makePlugin(json: makeURLInfoJSON(videoStreams: """
          {"id":80,"base_url":"https://cdn.example.com/720.m4s","backup_url":null,
           "bandwidth":1500000,"mime_type":"video/mp4","codecs":"avc1.640034","width":1280,"height":720,
           "frame_rate":"16000/672","sar":"1:1","start_with_sap":1,
           "segment_base":{"initialization":"0-999","index_range":"1000-1999"},"codecid":7},
          {"id":116,"base_url":"https://cdn.example.com/1080avc.m4s","backup_url":null,
           "bandwidth":2000000,"mime_type":"video/mp4","codecs":"avc1.640034","width":1920,"height":1080,
           "frame_rate":"16000/672","sar":"1:1","start_with_sap":1,
           "segment_base":{"initialization":"0-999","index_range":"1000-1999"},"codecid":7},
          {"id":116,"base_url":"https://cdn.example.com/1080hevc.m4s","backup_url":null,
           "bandwidth":3000000,"mime_type":"video/mp4","codecs":"hev1.1.6.L120.90","width":1920,"height":1080,
           "frame_rate":"16000/672","sar":"1:1","start_with_sap":1,
           "segment_base":{"initialization":"0-999","index_range":"1000-1999"},"codecid":12}
        """))

        var current: [UIMenuElement] = []
        let menus = plugin.addMenuItems(current: &current)

        // 返回结构：单个顶级「画质·…」菜单，children 才是按画质分组的子菜单
        guard let top = menus.first as? UIMenu else {
            XCTFail("应返回一个顶级画质菜单，实际：\(menus)")
            return
        }
        XCTAssertTrue(top.title.hasPrefix("画质·"), "顶级菜单应带当前画质：\(top.title)")
        let submenus = top.children.compactMap { $0 as? UIMenu }
        // 两条 116 流合并成一个子菜单，80 单独一个；画质降序
        XCTAssertEqual(submenus.count, 2, "三个流按画质分组后应是 2 个子菜单")
        XCTAssertEqual(submenus.first?.title.contains("高清 1080P60"), true,
                       "高画质在前：\(submenus.map(\.title))")
        // 单流子菜单标题带码率，多流子菜单只保留档位名
        XCTAssertEqual(submenus.last?.title.contains("Mbps"), true,
                       "单流命名含码率：\(submenus.map(\.title))")
    }

    func test_noStreams_returnsEmptyAndKeepsCurrentUntouched() throws {
        let plugin = try makePlugin(json: makeURLInfoJSON(videoStreams: ""))

        var current: [UIMenuElement] = []
        let menus = plugin.addMenuItems(current: &current)

        XCTAssertTrue(menus.isEmpty, "无可用画质时不产出菜单")
        XCTAssertTrue(current.isEmpty)
    }
}
