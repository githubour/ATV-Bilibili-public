//
//  BVideoStreamSelection.swift
//  ATV-Bilibili
//

import Foundation

/// 起播流的选择规则。资源加载器（真正生成播放列表）、CDN 起播测速、画质菜单勾选
/// 三处共用同一套规则，避免"菜单显示 AVC 最高档、实际播的是 HEVC 低档"这类不一致。
enum BVideoStreamSelection {
    /// AVC 优先：同一画质档位下存在 AVC 流时剔除 HEVC/HDR 变体；该档位没有 AVC 时保留 HEVC 兜底（如 4K 通常只有 HEVC）
    static func preferringAVC(_ videos: [VideoPlayURLInfo.DashInfo.DashMediaInfo],
                              preferAvc: Bool = Settings.preferAvc) -> [VideoPlayURLInfo.DashInfo.DashMediaInfo]
    {
        guard preferAvc else { return videos }
        var result = videos
        let grouped = Dictionary(grouping: videos, by: { $0.id })
        for (id, streams) in grouped where streams.contains(where: { !$0.isHevc }) {
            result.removeAll { $0.id == id && $0.isHevc }
        }
        return result
    }

    /// 默认起播流：动态范围优先（杜比视界 > HDR > SDR）→ 最高画质档位 → 同档优先 AVC → 同档取最高码率
    static func defaultStream(from videos: [VideoPlayURLInfo.DashInfo.DashMediaInfo],
                              preferAvc: Bool = Settings.preferAvc,
                              maxQn: Int = Settings.mediaQuality.qn) -> VideoPlayURLInfo.DashInfo.DashMediaInfo?
    {
        let candidates = preferringAVC(videos, preferAvc: preferAvc).filter { $0.id <= maxQn }
        guard !candidates.isEmpty else { return nil }

        // 有杜比视界就选杜比视界, 有 HDR 就选 HDR (画质上限需要放开到对应档位)
        guard let bestDynamicRange = candidates.map(\.dynamicRangeRank).max() else { return nil }
        let sameDynamicRange = candidates.filter { $0.dynamicRangeRank == bestDynamicRange }

        guard let highestQuality = sameDynamicRange.map(\.id).max() else { return nil }
        let sameQuality = sameDynamicRange.filter { $0.id == highestQuality }
        return sameQuality.filter { !$0.isHevc }.max(by: { $0.bandwidth < $1.bandwidth })
            ?? sameQuality.max(by: { $0.bandwidth < $1.bandwidth })
    }

    /// 播放列表选流：手动指定流 > 手动指定画质 > 默认最高画质
    static func select(videos: [VideoPlayURLInfo.DashInfo.DashMediaInfo],
                       streamIndex: Int?,
                       maxQuality: Int?,
                       preferAvc: Bool = Settings.preferAvc,
                       maxQn: Int = Settings.mediaQuality.qn) -> [VideoPlayURLInfo.DashInfo.DashMediaInfo]
    {
        if let streamIndex, videos.indices.contains(streamIndex) {
            return [videos[streamIndex]]
        }
        if let maxQuality {
            let matching = preferringAVC(videos, preferAvc: preferAvc).filter { $0.id == maxQuality }
            if let best = matching.max(by: { $0.bandwidth < $1.bandwidth }) {
                return [best]
            }
            return matching
        }
        if let best = defaultStream(from: videos, preferAvc: preferAvc, maxQn: maxQn) {
            return [best]
        }
        // 画质上限把可选流全滤掉了（例如上限 1080P 而服务端只给了更高档位），退回原列表避免播放列表为空
        return preferringAVC(videos, preferAvc: preferAvc)
    }
}

enum BVideoUrlUtils {
    static func sortUrls(base: String, backup: [String]?) -> [String] {
        var urls = [base]
        if let backup {
            urls.append(contentsOf: backup)
        }
        // 只把 PCDN 垫底；其余保持 API 返回顺序，具体快慢交给动态测速
        return urls.enumerated()
            .sorted { (tier($0.element), $0.offset) < (tier($1.element), $1.offset) }
            .map(\.element)
    }

    // PCDN 特征：带端口，或已知的 P2P CDN 域名（部分 PCDN 域名不带端口，仅靠端口判断会漏）
    static func isPCDN(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString) else {
            return false
        }
        if components.port != nil {
            return true
        }
        guard let host = components.host?.lowercased() else {
            return false
        }
        return host.hasSuffix("szbdyd.com") || host.hasSuffix("mcdn.bilivideo.cn")
    }

    /// 0 = 普通 CDN，1 = PCDN（仅作安全策略垫底，不再做 upos/akam 等静态速度假设）
    static func tier(_ urlString: String) -> Int {
        isPCDN(urlString) ? 1 : 0
    }

    static func convertVTTFormate(_ time: CGFloat) -> String {
        let seconds = Int(time)
        let hour = seconds / 3600
        let min = (seconds % 3600) / 60
        let second = CGFloat((seconds % 3600) % 60) + time - CGFloat(Int(time))
        return String(format: "%02d:%02d:%06.3f", hour, min, second)
    }

    static func convertToVTT(subtitle: [SubtitleContent]) -> String {
        var vtt = "WEBVTT\n\n"
        for model in subtitle {
            let from = convertVTTFormate(model.from)
            let to = convertVTTFormate(model.to)
            // hours:minutes:seconds.millisecond
            vtt.append("\(from) --> \(to)\n\(model.content)\n\n")
        }
        return vtt
    }
}

extension VideoPlayURLInfo.DashInfo.DashMediaInfo {
    var playableURLs: [String] {
        BVideoUrlUtils.sortUrls(base: base_url, backup: backup_url)
    }

    var isHevc: Bool {
        return codecs.starts(with: "hev") || codecs.starts(with: "hvc") || codecs.starts(with: "dvh1")
    }

    /// 杜比视界 (画质 id 126)
    var isDolbyVision: Bool {
        id == MediaQualityEnum.quality_hdr_dolby.qn
    }

    /// HDR10 / HLG (画质 id 125)
    var isHDR10: Bool {
        id == 125
    }

    /// 动态范围档位: 2 = 杜比视界, 1 = HDR, 0 = SDR
    var dynamicRangeRank: Int {
        if isDolbyVision { return 2 }
        if isHDR10 { return 1 }
        return 0
    }
}
