//
//  FollowsGridViewController.swift
//  ATV-Bilibili
//
//  Created by ATV-Bilibili contributors on 2026/10/11.
//

import Foundation
import UIKit

/// 关注页网格模式 (设置里可切换)
final class FollowsGridViewController: StandardVideoCollectionViewController<DynamicFeedData> {
    var lastOffset = ""
    private var nextSourcePage = 1

    override func setupCollectionView() {
        super.setupCollectionView()
        collectionVC.pageSize = 1
    }

    override func request(page: Int) async throws -> [DynamicFeedData] {
        if page == 1 {
            lastOffset = ""
            nextSourcePage = 1
        }

        for _ in 0..<6 {
            try Task.checkCancellation()
            let requestedOffset = lastOffset
            let info = try await WebRequest.requestFollowsFeed(offset: requestedOffset, page: nextSourcePage)
            try Task.checkCancellation()
            nextSourcePage += 1
            lastOffset = info.offset
            Logger.debug("request page\(nextSourcePage - 1) get count:\(info.videoFeeds.count) next offset:\(info.offset)")
            if !info.videoFeeds.isEmpty || !info.has_more || info.offset == requestedOffset {
                return info.videoFeeds
            }
        }
        return []
    }

    override func goDetail(with feed: DynamicFeedData) {
        let epid = feed.modules.module_dynamic.major?.pgc?.epid
        let detailVC = VideoDetailViewController.create(aid: feed.aid, cid: feed.cid, epid: epid)
        detailVC.present(from: self)
    }
}

extension WebRequest {
    struct DynamicFeedInfo: Codable {
        let items: [DynamicFeedData]
        let offset: String
        let has_more: Bool

        var videoFeeds: [DynamicFeedData] {
            items.filter { $0.aid != 0 || $0.modules.module_dynamic.major?.pgc?.epid != nil }
        }
    }

    static func requestFollowsFeed(offset: String, page: Int) async throws -> DynamicFeedInfo {
        var parameters: [String: Any] = ["type": "all", "timezone_offset": "-480", "page": page]
        if let offset = Int(offset) {
            parameters["offset"] = offset
        }
        return try await request(url: EndPoint.dynamicFeed, parameters: parameters)
    }
}

struct DynamicFeedData: Codable, PlayableData, DisplayData {
    var aid: Int {
        if let str = modules.module_dynamic.major?.archive?.aid {
            return Int(str) ?? 0
        }
        return 0
    }

    var cid: Int { 0 }

    var title: String {
        modules.module_dynamic.major?.archive?.title ?? modules.module_dynamic.major?.pgc?.title ?? ""
    }

    var ownerName: String {
        modules.module_author.name
    }

    var pic: URL? {
        URL(string: modules.module_dynamic.major?.archive?.cover ?? "") ?? modules.module_dynamic.major?.pgc?.cover
    }

    var avatar: URL? {
        URL(string: modules.module_author.face)
    }

    var date: String? {
        modules.module_author.pub_time
    }

    var overlay: DisplayOverlay? {
        let archive = modules.module_dynamic.major?.archive
        return .video(playText: archive?.stat?.play,
                      danmakuText: archive?.stat?.danmaku,
                      durationText: archive?.duration_text)
    }

    var feedFlowItem: FeedFlowItem? {
        if aid > 0 {
            return FeedFlowItem(aid: aid,
                                title: title,
                                ownerName: ownerName,
                                coverURL: pic,
                                avatarURL: avatar,
                                durationText: modules.module_dynamic.major?.archive?.duration_text ?? "",
                                viewCountText: modules.module_dynamic.major?.archive?.stat?.play ?? "",
                                danmakuCountText: modules.module_dynamic.major?.archive?.stat?.danmaku ?? "",
                                reasonText: date)
        }

        if let epid = modules.module_dynamic.major?.pgc?.epid, epid > 0 {
            return FeedFlowItem(aid: 0,
                                epid: epid,
                                title: title,
                                ownerName: ownerName,
                                coverURL: pic,
                                avatarURL: avatar,
                                durationText: "",
                                reasonText: date)
        }

        return nil
    }

    let type: String
    let basic: Basic
    let modules: Modules
    let id_str: String

    struct Basic: Codable, Hashable {
        let comment_id_str: String
        let comment_type: Int
    }

    struct Modules: Codable, Hashable {
        let module_author: ModuleAuthor
        let module_dynamic: ModuleDynamic

        struct ModuleAuthor: Codable, Hashable {
            let face: String
            let mid: Int
            let name: String
            let pub_time: String
        }

        struct ModuleDynamic: Codable, Hashable {
            let major: Major?

            struct Major: Codable, Hashable {
                let archive: Archive?
                let pgc: Pgc?

                struct Archive: Codable, Hashable {
                    let aid: String?
                    let cover: String?
                    let desc: String?
                    let title: String?
                    let duration_text: String?
                    let stat: Stat?

                    struct Stat: Codable, Hashable {
                        let danmaku: String?
                        let play: String?
                    }
                }

                struct Pgc: Codable, Hashable {
                    @LossyInt var epid: Int?
                    let title: String?
                    let cover: URL?
                    let jump_url: URL?
                }
            }
        }
    }
}
