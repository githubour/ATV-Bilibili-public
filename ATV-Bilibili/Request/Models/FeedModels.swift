//
//  FeedModels.swift
//  ATV-Bilibili
//

import Foundation

struct HistoryData: DisplayData, Codable, PlayableData {
    let pic: URL?

    let owner: VideoOwner
    /// 历史接口部分条目（番剧/课程）可能缺省 cid，PlayableData 要求非可选，兜底 0
    private let cidValue: Int?
    var cid: Int { cidValue ?? 0 }
    let aid: Int
    /// 观看进度（秒）。与 duration 同为秒，接口不给毫秒
    let progress: Int
    /// 全部分 P 的总时长（秒）；多 P 稿件不是当前这一 P 的时长
    let duration: Int
    let view_at: Int
    let stat: Stat?

    /// 最后观看的那一分 P（x/v2/history 的 page 对象）；单 P 稿件可能缺省
    private let lastPage: Page?
    /// archive / pgc / cheese / live / article ...
    let business: String?
    /// 3 普通视频 / 4 剧集 / 10 课程
    let type: Int?
    /// 剧集信息；只有番剧/影视条目才有
    private let bangumi: Bangumi?

    // displayData
    let title: String
    var ownerName: String { owner.name }
    var avatar: URL? { owner.face.flatMap(URL.init(string:)) }

    /// 最后观看的分 P cid。接口的 cid 字段固定是第 1P，
    /// 直接拿它续播多 P 稿件会跳回 P1 从头开始。
    var resumeCid: Int {
        if let lastPageCid = lastPage?.cid, lastPageCid > 0 { return lastPageCid }
        return cid
    }

    /// 续播目标分 P 的时长（秒）。用 duration（全 P 总和）算剩余分钟会算错
    var resumeDuration: Int {
        if let pageDuration = lastPage?.duration, pageDuration > 0 { return pageDuration }
        return duration
    }

    /// 剧集/课程必须走 PGC 链路（epid/seasonId）：当普通稿件直进播放器会请求错接口、也容易选错集
    var isPgcContent: Bool {
        business == "pgc" || business == "cheese" || type == 4 || type == 10
    }

    var epid: Int? { bangumi?.ep_id }
    var seasonId: Int? { bangumi?.season?.season_id }

    /// 直播/专栏没有可续播的视频进度
    var isPlayableBusiness: Bool {
        guard let business else { return true } // 老响应没有 business 时按稿件处理
        return business == "archive" || business == "pgc" || business == "cheese"
    }

    /// 冷启动续看横幅的筛选：已开始、未看完、内容可播
    var isResumeCandidate: Bool {
        guard isPlayableBusiness, progress > 0 else { return false }
        let total = resumeDuration
        // 距结尾不足 5 秒视为看完，避免每次启动都推一个马上结束的视频
        if total > 0, progress >= total - 5 { return false }
        return true
    }

    /// 横幅副标题的剩余分钟（向上取整，至少 1 分钟）；总时长未知时返回 nil
    var remainingMinutes: Int? {
        let total = resumeDuration
        guard total > 0 else { return nil }
        let remain = max(total - progress, 0)
        return max((remain + 59) / 60, 1)
    }

    struct Page: Codable, Hashable {
        let cid: Int?
        let duration: Int?
    }

    struct Bangumi: Codable, Hashable {
        let ep_id: Int?
        let season: Season?

        struct Season: Codable, Hashable {
            let season_id: Int?
        }
    }

    var overlay: DisplayOverlay? {
        let leftItems = [DisplayOverlay.DisplayOverlayItem]()
        var rightItems = [DisplayOverlay.DisplayOverlayItem]()
        rightItems.append(DisplayOverlay.DisplayOverlayItem(icon: nil, text: "\(TimeInterval(progress).timeString())/\(TimeInterval(duration).timeString())"))
        return DisplayOverlay(leftItems: leftItems, rightItems: rightItems)
    }

    /// 观看进度（0...1），驱动卡片底部进度条；progress 为 0（没看过/只标记）时不显示
    var watchedProgress: Double? {
        guard duration > 0, progress > 0 else { return nil }
        return Double(min(progress, duration)) / Double(duration)
    }

    struct Stat: Codable, Hashable {
        let view: Int
        let danmaku: Int
    }

    private enum CodingKeys: String, CodingKey {
        case pic, owner
        case cidValue = "cid"
        case aid, progress, duration, view_at, stat, title
        case lastPage = "page"
        case business, type, bangumi
    }
}

struct FavData: PlayableData, Codable {
    var cover: String
    var upper: VideoOwner
    var id: Int
    var type: Int?
    var title: String
    var ogv: Ogv?
    var ownerName: String { upper.name }
    var pic: URL? { URL(string: cover) }
    let duration: Int
    let cnt_info: CountInfo?
    let pubtime: Int

    struct Ogv: Codable, Hashable {
        let season_id: Int?
    }

    struct CountInfo: Codable, Hashable {
        let play: Int
        let danmaku: Int
    }

    var aid: Int {
        return id
    }

    var cid: Int {
        return 0
    }

    var date: String? {
        return ogv == nil ? DateFormatter.stringFor(timestamp: pubtime) : nil
    }

    var avatar: URL? { URL(string: upper.face ?? "") }
    var overlay: DisplayOverlay? {
        .video(play: cnt_info?.play, danmaku: cnt_info?.danmaku, durationText: TimeInterval(duration).timeString())
    }
}

class FavListData: Codable, Hashable {
    let title: String
    let id: Int
    var mid: Int?
    // 收藏夹是否为用户自己创建
    var createBySelf = false
    enum CodingKeys: String, CodingKey {
        case title, id, mid
    }

    static func == (lhs: FavListData, rhs: FavListData) -> Bool {
        return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
