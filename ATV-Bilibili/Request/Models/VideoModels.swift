//
//  VideoModels.swift
//  ATV-Bilibili
//

import Foundation

struct VideoDetail: Codable, Hashable {
    struct Info: Codable, Hashable {
        let aid: Int
        let cid: Int
        let title: String
        let videos: Int?
        let pic: URL?
        let desc: String?
        let owner: VideoOwner
        let pages: [VideoPage]?
        let dynamic: String?
        let bvid: String?
        let duration: Int
        let pubdate: Int?
        let ugc_season: UgcSeason?
        let redirect_url: URL?
        let stat: Stat
        var ctime: Int?
        struct Stat: Codable, Hashable {
            let favorite: Int
            let coin: Int
            let like: Int
            let share: Int
            let danmaku: Int
            let view: Int
        }

        struct UgcSeason: Codable, Hashable {
            let id: Int
            let title: String
            let cover: URL
            let mid: Int
            let intro: String
            let attribute: Int
            let sections: [UgcSeasonDetail]

            struct UgcSeasonDetail: Codable, Hashable {
                let season_id: Int
                let id: Int
                let title: String
                let episodes: [UgcVideoInfo]
            }

            struct UgcVideoInfo: Codable, Hashable, DisplayData {
                var ownerName: String { "" }
                var pic: URL? { arc.pic }
                let id: Int
                let aid: Int
                let cid: Int
                let arc: Arc
                let title: String

                struct Arc: Codable, Hashable {
                    let pic: URL
                    let ctime: Int
                }
            }
        }

        var durationString: String {
            TimeInterval(duration).timeString(style: .brief)
        }
    }

    struct Owner: Hashable, Codable {
        let following: Bool
        let follower: Int?
    }

    let View: Info
    let Related: [Info]
    let Card: Owner

    enum CodingKeys: String, CodingKey {
        case View, Related, Card
    }

    init(View: Info, Related: [Info], Card: Owner) {
        self.View = View
        self.Related = Related
        self.Card = Card
    }

    /// Related/Card 在某些稿件/风控响应里会缺失；不能因此让整个详情页解码失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        View = try container.decode(Info.self, forKey: .View)
        Related = try container.decodeIfPresent([Info].self, forKey: .Related) ?? []
        Card = try container.decodeIfPresent(Owner.self, forKey: .Card)
            ?? Owner(following: false, follower: nil)
    }
}

extension VideoDetail: DisplayData {
    var title: String { View.title }
    var ownerName: String { View.owner.name }
    var pic: URL? { View.pic }
    var avatar: URL? {
        if View.owner.face != nil {
            return URL(string: View.owner.face!)
        }
        return nil
    }

    var date: String? { DateFormatter.stringFor(timestamp: View.pubdate) }
}

extension VideoDetail.Info: DisplayData, PlayableData {
    var ownerName: String { owner.name }
    var avatar: URL? {
        if owner.face != nil {
            return URL(string: owner.face!)
        }
        return nil
    }

    var date: String? { DateFormatter.stringFor(timestamp: pubdate) }

    var overlay: DisplayOverlay? {
        .video(play: stat.view, danmaku: stat.danmaku, durationText: TimeInterval(duration).timeString())
    }
}

struct SubtitleResp: Codable {
    /// 无字幕的视频可能返回 "subtitles": null 而不是 []，
    /// 声明成非可选会解码失败并向上抛，导致整个 PlayerInfo 报废
    /// （调用处是 try?，静默变成 nil），连带章节标记、弹幕防遮挡、续播位置一起丢失。
    /// 这里声明为可选，读取处统一 `?? []`（读取时视为空数组，语义不变）。
    let subtitles: [SubtitleData]?
}

struct SubtitleData: Codable, Hashable {
    let lan_doc: String
    let subtitle_url: String?
    let lan: String

    var url: URL? {
        if let subtitle_url, let sub_url = URL(string: subtitle_url) {
            return sub_url.addSchemeIfNeed()
        }
        return nil
    }

    var subtitleContents: [SubtitleContent]?
}

struct VideoOwner: Codable, Hashable {
    let mid: Int
    let name: String
    var face: String?
}

struct VideoPage: Codable, Hashable {
    let cid: Int
    let page: Int
    let epid: Int?
    let from: String
    let part: String
}

struct PlayerInfo: Codable {
    let last_play_time: Int
    let subtitle: SubtitleResp?
    let view_points: [ViewPoint]?
    let dm_mask: MaskInfo?
    let last_play_cid: Int
    let is_upower_exclusive: Bool?
    var playTimeInSecond: Int {
        last_play_time / 1000
    }

    enum CodingKeys: String, CodingKey {
        case last_play_time, subtitle, view_points, dm_mask, last_play_cid, is_upower_exclusive
    }

    /// 续播相关字段在部分稿件/账号下可能缺失；整块解码失败会连带丢掉字幕、
    /// 章节和遮罩，所以这里只对这两个 Int 做 0 兜底，其余保持可选。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        last_play_time = try container.decodeIfPresent(Int.self, forKey: .last_play_time) ?? 0
        subtitle = try container.decodeIfPresent(SubtitleResp.self, forKey: .subtitle)
        view_points = try container.decodeIfPresent([ViewPoint].self, forKey: .view_points)
        dm_mask = try container.decodeIfPresent(MaskInfo.self, forKey: .dm_mask)
        last_play_cid = try container.decodeIfPresent(Int.self, forKey: .last_play_cid) ?? 0
        is_upower_exclusive = try container.decodeIfPresent(Bool.self, forKey: .is_upower_exclusive)
    }

    class ViewPoint: Codable {
        let type: Int
        let from: TimeInterval
        let to: TimeInterval
        let content: String
        let imgUrl: URL?

        var imageData: Data?

        enum CodingKeys: String, CodingKey {
            case type, from, to, content, imgUrl
        }
    }

    struct MaskInfo: Codable {
        let mask_url: URL?
        let fps: Int
    }
}

struct VideoPlayURLInfo: Codable {
    let quality: Int
    let format: String
    let timelength: Int
    let accept_format: String
    let accept_description: [String]
    let accept_quality: [Int]
    let video_codecid: Int
    let support_formats: [SupportFormate]
    let dash: DashInfo
    let clip_info_list: [ClipInfo]?

    class ClipInfo: Codable {
        let start: CGFloat
        let end: CGFloat
        let clipType: String?
        let toastText: String?

        var skipped: Bool? = false

        var customText: String {
            if clipType == "CLIP_TYPE_OP" {
                return "跳过片头"
            } else if clipType == "CLIP_TYPE_ED" {
                return "跳过片尾"
            } else {
                return toastText ?? "跳过"
            }
        }

        init(start: CGFloat, end: CGFloat, clipType: String?, toastText: String?) {
            self.start = start
            self.end = end
            self.clipType = clipType
            self.toastText = toastText
        }
    }

    struct SupportFormate: Codable {
        let quality: Int
        let format: String
        let new_description: String
        let display_desc: String
        let codecs: [String]?
    }

    struct DashInfo: Codable {
        let duration: Int
        let minBufferTime: CGFloat
        let video: [DashMediaInfo]
        let audio: [DashMediaInfo]?
        let dolby: DolbyInfo?
        let flac: FlacInfo?
        struct DashMediaInfo: Codable, Hashable {
            let id: Int
            let base_url: String
            let backup_url: [String]?
            let bandwidth: Int
            let mime_type: String
            let codecs: String
            let width: Int?
            let height: Int?
            let frame_rate: String?
            let sar: String?
            let start_with_sap: Int?
            let segment_base: DashSegmentBase
            let codecid: Int?
        }

        struct DashSegmentBase: Codable, Hashable {
            let initialization: String
            let index_range: String
        }

        struct DolbyInfo: Codable {
            let type: Int
            let audio: [DashMediaInfo]?
        }

        struct FlacInfo: Codable {
            let display: Bool
            let audio: DashMediaInfo?
        }
    }
}

struct SubtitleContent: Codable, Hashable {
    let from: CGFloat
    let to: CGFloat
    let location: Int
    let content: String
}
