//
//  BilibiliVideoResourceLoaderDelegate+HLS.swift
//  ATV-Bilibili
//
//  master playlist 的纯声明规则: 带宽峰值换算、FRAME-RATE、CHANNELS、
//  杜比视界 profile 声明、音轨计划、字幕轨选择。
//  这些都是无副作用的静态函数, 单测直接调用（见 BilibiliVideoResourceLoaderDelegateTests /
//  SubtitlePreferenceTests）；拆文件不改变可见性与行为。
//

import Foundation

extension BilibiliVideoResourceLoaderDelegate {
    /// 这是**内容层**的判断，与 SubtitlePlugin 里"本次该选哪条轨"是两件事：
    /// 后者管选择状态，这里管"选中之后有没有东西可渲染"。
    static func wantedSubtitleLan(autoSelect: Bool, preferLan: String) -> String? {
        guard autoSelect, !preferLan.isEmpty else { return nil }
        return preferLan
    }

    /// 偏好语言 → 实际可用轨道 lan。精确优先，否则按主语言模糊匹配
    /// （ai-zh ↔ zh-CN）。必须与 SubtitlePlugin 的选轨规则共用：插件会选中
    /// 模糊命中的轨道，而这里若仍拿原始偏好做精确比对，就会把该轨清单回空，
    /// 表现为"菜单显示已选中，画面却没有字幕"。
    static func resolvedSubtitleLan(preference: String, availableLans: [String]) -> String? {
        guard !preference.isEmpty else { return nil }
        if availableLans.contains(preference) { return preference }
        let base = subtitleBaseLanguage(of: preference)
        guard !base.isEmpty else { return nil }
        return availableLans.first { subtitleBaseLanguage(of: $0) == base }
    }

    private static func subtitleBaseLanguage(of lan: String) -> String {
        var l = lan
        if l.hasPrefix("ai-") { l = String(l.dropFirst(3)) }
        return String(l.split(separator: "-").first ?? "")
    }

    /// DASH manifest 的 bandwidth 是平均码率，而 HLS 的 BANDWIDTH 要求的是分片峰值码率。
    /// 直接照搬会让 CoreMedia 每拉一个分片都判定 "Segment exceeds specified bandwidth for
    /// variant" (-12318) 并自行上调内部估计，ABR 从起播起就在用错误的依据决策。
    ///
    /// 实测 B 站分片的峰值约为平均的 1.5 倍：785kbps 的流被上调到 1.21Mbps，
    /// 3.17Mbps 的流被上调到 4.81Mbps。真实平均值仍通过 AVERAGE-BANDWIDTH 如实声明，
    /// 稳态选流靠它，所以这里的峰值宁可略高。
    /// internal：BVideoQualityPlugin 反推 ABR 档位时复用同一系数，避免两处 1.5 硬编码脱节
    static func peakBandwidth(forAverage average: Int) -> Int {
        return Int(Double(average) * 1.5)
    }

    /// HLS 的 FRAME-RATE 是十进制数值，B 站返回的也正是十进制字符串
    /// （实测 '30.303' / '23.810' / '24.390' / '60.000'），原样透传即可。
    /// 原实现在 HDR10 分支把 >30 的帧率一律改写成 30，而紧随其后的 60fps 归一化
    /// 读到的已是被覆盖过的值 —— HDR10 60fps 内容因此被声明成 30fps。
    /// FRAME-RATE 会参与 `appliesPreferredDisplayCriteriaAutomatically` 的显示模式匹配
    /// （见 BVideoPlayPlugin.shouldApplyContentMatch），误报 30fps 会让电视切到 30Hz 档，画面抖动。
    static func hlsFrameRate(from raw: String?) -> String {
        guard let raw, Double(raw) != nil else { return "25" }
        return raw
    }

    /// HLS 的 CHANNELS 属性（quoted-string）让系统在清单层就识别多声道音轨。
    /// 不声明时，系统在选定音轨前只能拿到"未知声道数"，5.1/Atmos 尤其依赖它。
    /// B 站音轨：ec-3 / ac-3 为杜比 5.1，AAC 与 FLAC 为立体声。
    static func hlsChannels(forCodecs codecs: String) -> Int? {
        let lower = codecs.lowercased()
        if lower.contains("ec-3") || lower.contains("ac-3") { return 6 }
        if lower.hasPrefix("mp4a") || lower.contains("flac") { return 2 }
        return nil
    }

    /// 杜比视界的 HLS 清单声明，按 Apple《HLS authoring specification for Apple devices》附录的对照表落表。
    /// 附录里 DV 只有两行可用组合，并强调「兼容品牌与 VIDEO-RANGE 互为交叉校验，缺任何一个都是错的」：
    ///
    /// | 编码 | CODECS | SUPPLEMENTAL-CODECS | VIDEO-RANGE |
    /// |---|---|---|---|
    /// | Dolby Vision 8.4 | hvc1.2.4.L153.b0 | dvh1.08.07/db4h | HLG |
    /// | Dolby Vision 8.1 | hvc1.2.4.L150    | dvh1.08.06/db1p | PQ  |
    ///
    /// Profile 5 是单层 10-bit HEVC（规范 1.9 要求 Profile 5 且 Level ≤ 7），本身不向后兼容：
    /// 基层就是 CODECS 里的那个 sample type，不加 SUPPLEMENTAL-CODECS，动态范围 PQ。
    /// 查不到对照表的编码返回 nil —— 调用方不猜动态范围，也不伪造基层声明。
    /// - Returns: 要写进 CODECS 的基层编码 / SUPPLEMENTAL-CODECS 的值（含前导逗号，空串表示不需要）/ VIDEO-RANGE
    static func dolbyVisionDeclaration(forCodecs codecs: String)
        -> (baseCodecs: String, supplementary: String, videoRange: String)?
    {
        let prefix = "dvh1."
        guard codecs.hasPrefix(prefix) else { return nil }
        let parts = codecs.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        switch parts[0] {
        case "05":
            // 单层、非向后兼容：CODECS 保持原值即可
            return (codecs, "", "PQ")
        case "08":
            // Profile 8 是「HDR 基层 + DV 元数据」的向后兼容形态，兼容品牌由子版本决定：
            // 8.4 → HLG(db4h)、8.1 → HDR10(db1p)。level 位只是同一子版本下的不同档次
            // （附录样例用 .07/.06，历史上也见过 .03），沿用既有映射范围，不按 level 细分。
            switch parts[1] {
            case "03", "07":
                return ("hvc1.2.4.L153.b0", ",SUPPLEMENTAL-CODECS=\"\(codecs)/db4h\"", "HLG")
            case "06":
                return ("hvc1.2.4.L150", ",SUPPLEMENTAL-CODECS=\"\(codecs)/db1p\"", "PQ")
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// 规划音频 rendition。顺序即优先级：第一条被写成 DEFAULT=YES，成为起播音轨。
    /// 之前只用码率命名（"音轨 (448kbps)"），用户无从分辨杜比全景声 / 无损 / 立体声，
    /// 而这三种来源本来就是已知的。
    static func planAudioTracks(for dash: VideoPlayURLInfo.DashInfo,
                                includeLossless: Bool = Settings.losslessAudio) -> [AudioTrackPlan]
    {
        var plans = [AudioTrackPlan]()
        if includeLossless {
            if let dolby = dash.dolby?.audio?.max(by: { $0.bandwidth < $1.bandwidth }),
               !dolby.playableURLs.isEmpty
            {
                plans.append(AudioTrackPlan(info: dolby,
                                            urls: dolby.playableURLs,
                                            label: "杜比全景声 (\(dolby.codecs), \(dolby.bandwidth / 1000)kbps)"))
            } else if let flac = dash.flac?.audio,
                      !flac.playableURLs.isEmpty
            {
                plans.append(AudioTrackPlan(info: flac,
                                            urls: flac.playableURLs,
                                            label: "Hi-Res 无损 (\(flac.bandwidth / 1000)kbps)"))
            }
        }
        // 普通音轨取码率最高的一条。B 站 dash.audio 的数组顺序并不固定
        // （实测同一视频两次请求分别为 [30232,30280,30216] 与 [30232,30216,30280]），
        // 原先取 .first 会稳定拿到 132kbps 的中档，丢掉 30280(192k~302k) 的最高档。
        if let best = dash.audio?.max(by: { $0.bandwidth < $1.bandwidth }),
           !best.playableURLs.isEmpty
        {
            plans.append(AudioTrackPlan(info: best,
                                        urls: best.playableURLs,
                                        label: "立体声 (AAC, \(best.bandwidth / 1000)kbps)"))
        }
        return plans
    }
}
