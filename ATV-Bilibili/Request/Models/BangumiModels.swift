//
//  BangumiModels.swift
//  ATV-Bilibili
//

import Foundation

struct BangumiSeasonInfo: Codable {
    let main_section: BangumiInfo
    let section: [BangumiInfo]
}

struct BangumiInfo: Codable, Hashable {
    struct Episode: Codable, Hashable {
        let id: Int
        let aid: Int
        let cid: Int
        let cover: URL
        let long_title: String
        let title: String

        enum CodingKeys: String, CodingKey {
            case id, aid, cid, cover, long_title, title
        }

        init(from decoder: Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            aid = try container.decode(Int.self, forKey: .aid)
            cid = try container.decode(Int.self, forKey: .cid)
            cover = try container.decode(URL.self, forKey: .cover)
            long_title = try container.decodeIfPresent(String.self, forKey: .long_title) ?? ""
            title = try container.decode(String.self, forKey: .title)
        }
    }

    struct UserStatus: Codable, Hashable {
        struct Progress: Codable, Hashable {
            let last_time: Int // 最后观看的时间进度 | 单位为秒
            let last_ep_id: Int
            let last_ep_index: String // 最后观看的标题
        }

        let progress: Progress?
    }

    struct Section: Codable, Hashable {
        let episodes: [Episode]
    }

    let type: Int
    let season_id: Int
    let episodes: [Episode] // 正片剧集列表
    let user_status: UserStatus?
    let section: [Section]?

    func findEpisodeById(_ epid: Int) -> Episode? {
        if let epi = episodes.first(where: { $0.id == epid }) {
            return epi
        }

        for sec in section ?? [] {
            if let epi = sec.episodes.first(where: { $0.id == epid }) {
                return epi
            }
        }

        return nil
    }
}

struct BangumiSeasonView: Codable, Hashable {
    struct Episode: Codable, Hashable {
        let ep_id: Int
        let aid: Int
        let cid: Int
        let bvid: String?
        let duration: Int
        let cover: URL
        let index_title: String?
        let index: String
        let pub_real_time: String
        let section_type: Int

        var pubdate: Int? {
            if let date = DateFormatter.bilibiliISODateTime.date(from: pub_real_time) {
                return Int(date.timeIntervalSince1970)
            }
            return nil
        }

        var durationSeconds: Int {
            return Int(duration / 1000)
        }
    }

    struct UpInfo: Codable, Hashable {
        let mid: Int
        let uname: String
        let avatar: String
        let follower: Int?
    }

    let up_info: UpInfo
    let episodes: [Episode]
    let title: String
    let series_title: String
    let evaluate: String
}

struct UserEpisodeInfo: Codable, Hashable {
    struct RelatedUp: Codable, Hashable {
        let avatar: String
        let is_follow: Int
        let mid: Int
        let uname: String
    }

    struct Stat: Codable, Hashable {
        let coin: Int
        let dm: Int
        let like: Int
        let reply: Int
        let view: Int
    }

    struct UserCommunity: Codable, Hashable {
        let coin_number: Int
        let favorite: Int
        let is_original: Int
        let like: Int
    }

    let related_up: [RelatedUp]
    let stat: Stat
    let user_community: UserCommunity
}
