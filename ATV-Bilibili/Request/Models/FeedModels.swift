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
    let progress: Int
    let duration: Int
    let view_at: Int
    let stat: Stat?

    // displayData
    let title: String
    var ownerName: String { owner.name }
    var avatar: URL? { owner.face.flatMap(URL.init(string:)) }

    var date: String? {
        DateFormatter.relativeTimeStringFor(timestamp: view_at)
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
