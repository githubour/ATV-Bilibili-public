//
//  SeasonModels.swift
//  ATV-Bilibili
//
//  UP 空间「合集」相关接口模型。
//

import Foundation

/// 合集列表 / 合集内视频共用的分页信息。
struct SeasonPageInfo: Codable, Hashable {
    let page_num: Int?
    let page_size: Int?
    let total: Int?
}

/// `x/polymer/web-space/seasons_series_list` 的 data 部分。
/// 注意 page.total 统计的是「合集 + 列表/系列」的总数，本 App 只消费 seasons_list。
struct UpSpaceSeasonsResponse: Codable {
    let items_lists: ItemsLists

    struct ItemsLists: Codable {
        let page: SeasonPageInfo?
        let seasons_list: [Season]
    }

    struct Season: Codable, Hashable {
        let meta: UpSpaceSeasonMeta
    }
}

/// 合集元信息。archives/recent_aids 等预览字段用不到，Codable 会自动忽略。
struct UpSpaceSeasonMeta: Codable, Hashable {
    let mid: Int?
    let season_id: Int
    let title: String
    let cover: URL?
    let total: Int
    let description: String?
    let name: String?
}

/// `x/polymer/web-space/seasons_archives_list` 的 data 部分。
struct SeasonArchivesResponse: Codable {
    let archives: [SeasonArchive]
    let page: SeasonPageInfo?
}

/// 合集内单个稿件。该接口不返回 cid，播放时由详情页解析。
struct SeasonArchive: Codable, Hashable {
    let aid: Int
    let title: String
    let pic: URL?
    let duration: Int?
    let ctime: Int?
    let pubdate: Int?
    let stat: Stat?

    struct Stat: Codable, Hashable {
        let view: Int?
        let danmaku: Int?
    }
}
