//
//  BilibiliVideoResourceLoaderDelegate.swift
//  MPEGDASHAVPlayerDemo
//
//  Created by yicheng on 2022/08/20.
//  Copyright © 2022 yicheng. All rights reserved.
//

import Alamofire
import AVFoundation
import Swifter
import UIKit

class BilibiliVideoResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    enum URLs {
        static let customScheme = "atv"
        static let customPrefix = customScheme + "://list/"
        static let play = customPrefix + "play"
        static let customSubtitlePrefix = customScheme + "://subtitle/"
        static let customDashPrefix = customScheme + "://dash/"
    }

    struct PlaybackInfo {
        let info: VideoPlayURLInfo.DashInfo.DashMediaInfo
        /// 该条目的 CDN 候选（base_url 在前、backup 在后）。视频 variant 只带自己那一个
        /// ——多 CDN 靠 AVPlayer 在 variant 之间切换；音轨把全部候选带上，供兜底清单挑 host。
        let urls: [String]
        let duration: Int

        /// 兜底清单（sidx 探测失败走的那条路）用的 URL：优先与播放器当前选中的 CDN 同 host，
        /// 否则退到第一个候选。原先固定用第一个候选，音轨落到慢/挂的 CDN 就没有任何退路。
        func fallbackURL(preferringHost host: String?) -> String {
            guard let host, !host.isEmpty else { return urls.first ?? "" }
            return urls.first { $0.urlHost == host } ?? urls.first ?? ""
        }
    }

    /// 音轨计划。必须先生成、再写视频 variant：variant 的 CODECS 要带上音频编码，
    /// 而 master playlist 只被 AVPlayer 读一次，写完视频条目就无法回头补。
    struct AudioTrackPlan {
        let info: VideoPlayURLInfo.DashInfo.DashMediaInfo
        /// 全部 CDN 候选，不是只取第一个 —— 音轨不和视频共用 variant 切换机制，
        /// 只能靠这里带着的候选列表在兜底清单里换 host
        let urls: [String]
        /// 音轨在播放器音频菜单里的名字，按来源区分（杜比/无损/立体声）
        let label: String
    }

    /// 已生成的 master playlist。播放期它只被 AVPlayer 读一次，
    /// 这里放开内部读权限，供单测断言清单结构（音轨声道数/编码/帧率等声明）。
    private(set) var masterPlaylist = ""
    /// 本次装配的音频 rendition 计划，顺序即优先级（第一条成为 DEFAULT=YES 的起播音轨）
    private var audioTracks = [AudioTrackPlan]()

    private let badRequestErrorCode = 455

    private var playlists = [String]()
    /// 跨线程共享的字幕缓存（锁保护，见下方 sharedStateLock 说明）
    private var _subtitles = [String: String]()
    private var videoInfo = [PlaybackInfo]()
    // sidx 探测结果进程级共享，缓存键 = (流信息 + preferredHost)：
    // preferredHost 参与判键，不会把一个播放器选中的 CDN 泄漏给另一个并发播放器；
    // 同键的重复请求(切画质/换 host 往返)直接复用，免去重复下载
    private let segmentInfoCache = SidxDownloader.shared
    private var hasAudioInMasterListAdded = false
    private var hasSubtitle = false
    /// 与 `playlists` 一一对应的字幕轨 lan（原始值，未剥 ai- 前缀），用于判断"这条轨该不该给内容"
    private var subtitleLans = [String]()

    /// 空字幕清单：结构完全合法，只是没有任何 cue。用于压制系统的自动选轨，见
    /// `handleCustomPlaylistRequest` 里 atv://list/N 分支的说明。
    private static let emptySubtitlePlaylist = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:1
    #EXT-X-MEDIA-SEQUENCE:0
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-ENDLIST

    """

    /// 用户是否明确要字幕（要哪一条）。没要 → 返回 nil，此时所有字幕轨都只给空清单。
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

    private var httpServer = HttpServer()
    private var aid = 0
    private(set) var isHDR = false

    /// 跨线程共享状态同步层：这几个字段不满足 masterPlaylist/playlists 那套
    /// 「setDelegate 前写完、之后只读」的 happens-before 论证——
    /// subtitles 在资源加载 Task（全局并发执行器）写、Swifter HTTP 服务的 socket 线程读；
    /// currentSegmentHost 在 getVideoPlayList 的后台 Task 写、主线程诊断定时器（每 5s）读；
    /// cdnCandidates / primaryVideoBandwidth 在装配期写、播放器插件主线程读。
    /// 统一一把 NSLock 收口；锁内只有赋值/取值，无任何回调、IO 或字典重组之外的操作。
    private let sharedStateLock = NSLock()
    private var _cdnCandidates = [String]()
    private var _primaryVideoBandwidth = 0
    private var _currentSegmentHost: String?

    /// 首选视频流的全部 CDN 候选，按 host 去重，供 CDNDiagnostics 实测
    var cdnCandidates: [String] {
        sharedStateLock.lock(); defer { sharedStateLock.unlock() }
        return _cdnCandidates
    }

    /// 首选视频流的声明带宽（bps），access log 的 indicatedBitrate 尚未就绪时作健康检测兜底
    var primaryVideoBandwidth: Int {
        sharedStateLock.lock(); defer { sharedStateLock.unlock() }
        return _primaryVideoBandwidth
    }

    /// 最近一次生成媒体播放列表时实际选用的分片 host
    var currentSegmentHost: String? {
        sharedStateLock.lock(); defer { sharedStateLock.unlock() }
        return _currentSegmentHost
    }

    private func setCdnDiagnostics(candidates: [String], primaryBandwidth: Int) {
        sharedStateLock.lock(); defer { sharedStateLock.unlock() }
        _cdnCandidates = candidates
        _primaryVideoBandwidth = primaryBandwidth
    }

    private func setCurrentSegmentHost(_ host: String?) {
        sharedStateLock.lock(); defer { sharedStateLock.unlock() }
        _currentSegmentHost = host
    }

    func hasSubtitleVTT(for key: String) -> Bool {
        sharedStateLock.lock(); defer { sharedStateLock.unlock() }
        return _subtitles[key] != nil
    }

    func storeSubtitleVTT(_ vtt: String, for key: String) {
        sharedStateLock.lock(); defer { sharedStateLock.unlock() }
        _subtitles[key] = vtt
    }

    func subtitleVTT(for key: String) -> String? {
        sharedStateLock.lock(); defer { sharedStateLock.unlock() }
        return _subtitles[key]
    }

    /// 实际传输模式（内部执行模式，非用户设置）。默认 .direct 保持原行为。
    private(set) var transportMode: MediaTransportMode = .direct
    /// 播放器实际生效的传输模式：代理启动失败时播放列表已回退直连 URI，
    /// 此时按 .direct 处理，避免错误进入加速恢复流程。
    var effectiveTransportMode: MediaTransportMode {
        transportMode == .direct ? .direct : (proxyAvailable ? transportMode : .direct)
    }

    /// 本地代理是否可用（服务器启动成功且已注册媒体）。不可用时播放列表回退直连。
    private(set) var proxyAvailable = false
    /// 本地代理监听端口（0 表示未启动）。生成媒体播放列表时用它拼接本地 URL。
    private var httpPort = 0
    /// 媒体代理注册表（线程安全，Swifter 同步 handler 与播放列表生成并发访问）。
    private let proxyRegistry = MediaProxyRegistry()
    private let diagLock = NSLock()
    private var _accelerationText = ""
    /// 播放中途检测到当前 host 吞吐撑不住时，外部（BVideoPlayPlugin）指定的优先 host，
    /// sidx 探测会把它排到候选队首，覆盖默认 URL 顺序
    private var preferredHost: String?
    deinit {
        httpServer.stop()
    }

    /// 加速诊断文本（同步读取，供 DebugPlugin 展示；敏感签名已剔除）。
    var accelerationDebugInfo: String {
        diagLock.lock()
        defer { diagLock.unlock() }
        return _accelerationText
    }

    private func updateAccelerationText(_ text: String) {
        diagLock.lock()
        _accelerationText = text
        diagLock.unlock()
    }

    private func reset() {
        playlists.removeAll()
        subtitleLans.removeAll()
        audioTracks.removeAll()
        hasAudioInMasterListAdded = false
        proxyAvailable = false
        proxyRegistry.removeAll()
        updateAccelerationText("")
        masterPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-INDEPENDENT-SEGMENTS


        """
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

    private func addVideoPlayBackInfo(info: VideoPlayURLInfo.DashInfo.DashMediaInfo, url: String, duration: Int) {
        let isDolby = info.isDolbyVision
        let isHDR10 = info.isHDR10
        // hdr 10 formate exp: hev1.2.4.L156.90
        //  Codec.Profile.Flags.TierLevel.Constraints
        let isHDR = isDolby || isHDR10
        if isHDR {
            self.isHDR = true
        }
        var videoRange: String? = isHDR ? "HLG" : "SDR"
        var codecs = info.codecs
        var supplementCodesc = ""
        let framerate = Self.hlsFrameRate(from: info.frame_rate)
        // 杜比视界的清单声明按 Apple《HLS authoring specification》附录的对照表落表，
        // 见 dolbyVisionDeclaration(forCodecs:)。原先是对 codecs 字符串做等值判断，
        // 查不到就静默留一个猜出来的 HLG —— 附录明确说兼容品牌与 VIDEO-RANGE 互为交叉校验，
        // 填错比不填更糟，所以未识别时干脆不带 VIDEO-RANGE。
        if let declaration = Self.dolbyVisionDeclaration(forCodecs: info.codecs) {
            codecs = declaration.baseCodecs
            supplementCodesc = declaration.supplementary
            videoRange = declaration.videoRange
        } else if info.codecs.hasPrefix("dvh1.") {
            videoRange = nil
            Logger.warn("[hls] 对照表里没有的杜比视界编码，不声明 VIDEO-RANGE: \(info.codecs)")
        } else if isHDR10 {
            videoRange = "PQ"
        } else if isHDR {
            Logger.warn("[hls] unknown hdr codecs: \(info.codecs)")
        }
        // VIDEO-RANGE 是可选属性：查不到对照表时宁可省掉，也不猜
        let videoRangeAttr = videoRange.map { ",VIDEO-RANGE=\($0)" } ?? ""

        if supplementCodesc.count > 0 {
            supplementCodesc = ",SUPPLEMENTAL-CODECS=\"\(supplementCodesc)\""
        }
        // variant 的 CODECS 需覆盖该 variant 用到的全部编码（Apple HLS 规范）。
        // 音频走独立的 EXT-X-MEDIA 组，编码只能在这里声明 —— 不声明时系统在清单层
        // 只看到视频编码，ec-3（杜比全景声）的识别与透传就退化成"看解封装结果"。
        // 取 DEFAULT=YES 那条（audioTracks 首条）的编码。
        let masterCodecs = audioTracks.first.map { "\(codecs),\($0.info.codecs)" } ?? codecs
        // 没有音轨时不引用音频组，避免 AUDIO="audio" 指向不存在的 GROUP-ID
        let leadingAttrs = [
            audioTracks.isEmpty ? nil : "AUDIO=\"audio\"",
            hasSubtitle ? "SUBTITLES=\"subs\"" : nil,
        ].compactMap { $0 }.joined(separator: ",")
        let leading = leadingAttrs.isEmpty ? "" : leadingAttrs + ","
        let content = """
        #EXT-X-STREAM-INF:\(leading)CODECS="\(masterCodecs)"\(supplementCodesc),RESOLUTION=\(info.width ?? 0)x\(info.height ?? 0),FRAME-RATE=\(framerate),BANDWIDTH=\(Self.peakBandwidth(forAverage: info.bandwidth)),AVERAGE-BANDWIDTH=\(info.bandwidth)\(videoRangeAttr)
        \(URLs.customDashPrefix)\(videoInfo.count)?codec=\(info.codecs)&rate=\(info.frame_rate ?? framerate)&width=\(info.width ?? 0)&host=\(URL(string: url)?.host ?? "none")&range=\(info.id)

        """
        masterPlaylist.append(content)
        videoInfo.append(PlaybackInfo(info: info, urls: [url], duration: duration))
    }

    private func collectCDNCandidates(from video: VideoPlayURLInfo.DashInfo.DashMediaInfo?) {
        guard let video else {
            setCdnDiagnostics(candidates: [], primaryBandwidth: 0)
            return
        }
        var seenHosts = Set<String>()
        let candidates = video.playableURLs.filter { url in
            guard let host = url.urlHost else { return false }
            return seenHosts.insert(host).inserted
        }
        setCdnDiagnostics(candidates: candidates, primaryBandwidth: video.bandwidth)

        let detail = candidates
            .map { url in
                let host = url.urlHost ?? "?"
                return BVideoUrlUtils.isPCDN(url) ? "  PCDN \(host)" : "  \(host)"
            }
            .joined(separator: "\n")
        Logger.info("cdn candidates for qn \(video.id) (\(video.bandwidth / 1000)kbps):\n\(detail)")
    }

    private func getVideoPlayList(info: PlaybackInfo) async -> String {
        let sidxResult = await segmentInfoCache.sidx(from: info.info, preferredHost: preferredHost)
        let inits = info.info.segment_base.initialization.components(separatedBy: "-")
        guard let moovIdxStr = inits.last,
              let moovIdx = Int(moovIdxStr),
              let moovOffset = inits.first,
              let offsetStr = info.info.segment_base.index_range.components(separatedBy: "-").last,
              var offset = Int(offsetStr),
              let sidxResult = sidxResult
        else {
            // 兜底清单：拿不到 sidx 时按候选列表挑一个 URL。音轨带着全部 CDN 候选，
            // 这里会优先跟随播放器当前选中的 host，而不是死绑第一个候选
            let fallbackURL = info.fallbackURL(preferringHost: preferredHost)
            setCurrentSegmentHost(fallbackURL.urlHost)
            return """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:\(info.duration)
            #EXT-X-MEDIA-SEQUENCE:1
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:\(info.duration)
            \(fallbackURL)
            #EXT-X-ENDLIST
            """
        }

        // 使用 sidx 实际下载成功的 URL——它已经完成了对 CDN 可用性的探测，
        // 首选 CDN 挂掉时 segment 会整体切到探测成功的备用 URL
        let segment = sidxResult.sidx
        let segmentURL = sidxResult.url
        setCurrentSegmentHost(segmentURL.urlHost)
        // sidx 索引字节作为跨 CDN 等价性验证的信任锚点：它是播放前已从探测
        // 成功的 URL 取回的原始字节，后续各 CDN 的同区间样本必须与之逐字节一致。
        // 锚点设置与媒体请求并发进行，先到的下载请求可能回退为双边采样，不影响正确性。
        if let anchorRange = Self.indexRange(info.info),
           sidxResult.indexBytes.count == anchorRange.length,
           let downloader = proxyRegistry.downloader(for: info.info)
        {
            await downloader.setTrustAnchor(range: anchorRange, bytes: sidxResult.indexBytes)
        }
        // 代理启用且媒体已成功注册时，用本地 HTTP URL 替换 CDN 地址；
        // 保留原 Range、分段持续时间和全部 HLS 标签。SIDX 失败回退分支保持直连。
        let mediaURL = mediaTransportURL(for: info.info) ?? segmentURL
        var playList = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(segment.maxSegmentDuration() ?? info.duration)
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="\(mediaURL)",BYTERANGE="\(moovIdx + 1)@\(moovOffset)"

        """
        offset += 1
        for segInfo in segment.segments {
            let segStr = """
            #EXTINF:\(Double(segInfo.duration) / Double(segment.timescale)),
            #EXT-X-BYTERANGE:\(segInfo.size)@\(offset)
            \(mediaURL)

            """
            playList.append(segStr)
            offset += (segInfo.size)
        }

        playList.append("\n#EXT-X-ENDLIST")

        return playList
    }

    private func addAudioPlayBackInfo(plan: AudioTrackPlan, duration: Int) {
        let isFirst = !hasAudioInMasterListAdded
        let defaultStr = isFirst ? "YES" : "NO"

        // CHANNELS 让系统在清单层就识别多声道音轨（5.1 尤其依赖），推导不出时省掉该属性
        let channels = Self.hlsChannels(forCodecs: plan.info.codecs).map { ",CHANNELS=\"\($0)\"" } ?? ""

        let content = """
        #EXT-X-MEDIA:TYPE=AUDIO,DEFAULT=\(defaultStr),AUTOSELECT=YES,GROUP-ID="audio",LANGUAGE="zh",NAME="\(plan.label)"\(channels),URI="\(URLs.customDashPrefix)\(videoInfo.count)"

        """

        masterPlaylist.append(content)

        // 只有在真正添加音轨时才更新状态
        hasAudioInMasterListAdded = true
        videoInfo.append(PlaybackInfo(info: plan.info, urls: plan.urls, duration: duration))
    }

    private func addSubtitleData(lang: String, name: String, duration: Int, url: String) {
        // 索引对齐：subtitleLans 与 playlists 必须在同一次调用里各加一项
        subtitleLans.append(lang)
        var lang = lang
        if lang.hasPrefix("ai-") {
            lang = String(lang.dropFirst(3))
        }
        // 字幕轨一律不声明默认: 选中/关闭完全由 SubtitlePlugin 显式管理。
        // 声明 DEFAULT=YES 会让系统在字幕分组加载完成前抢先拉起一条, 闪出字幕。
        let master = """
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="\(lang)",NAME="\(name)",AUTOSELECT=NO,DEFAULT=NO,URI="\(URLs.customPrefix)\(playlists.count)"

        """
        masterPlaylist.append(master)

        let playList = """
        #EXTM3U
        #EXT-X-TARGETDURATION:\(duration)
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:\(duration),

        \(URLs.customSubtitlePrefix)\(url.addingPercentEncoding(withAllowedCharacters: .afURLQueryAllowed) ?? url)
        #EXT-X-ENDLIST

        """
        playlists.append(playList)
    }

    func setBilibili(info: VideoPlayURLInfo, subtitles: [SubtitleData], aid: Int, maxQuality: Int? = nil, streamIndex: Int? = nil, preferredHost: String? = nil, transportMode: MediaTransportMode = .direct) {
        self.aid = aid
        self.preferredHost = preferredHost
        self.transportMode = transportMode
        reset()
        // 只有带有效 URL 的轨道才会真正写入 EXT-X-MEDIA；先过滤再判断，
        // 否则全 nil 时 master 会声明一个空的 SUBTITLES 组。
        let validSubtitles = subtitles.filter { $0.url != nil }
        hasSubtitle = !validSubtitles.isEmpty
        // 手动指定流/画质仍按原逻辑精确选流；默认模式直接锁定可用的最高画质（同档优先 AVC），
        // 不再保留低档位后备 —— 混排多档位时 AVPlayer 的 ABR 会自己爬升，起播常落在 HEVC/低码率档。
        let videos = BVideoStreamSelection.select(videos: info.dash.video,
                                                  streamIndex: streamIndex,
                                                  maxQuality: maxQuality)

        collectCDNCandidates(from: videos.first)

        // 音轨先规划、再写视频条目：video variant 的 CODECS 需要带上音频编码，
        // 而 master playlist 只被 AVPlayer 读一次，不能写完视频再回头补。
        audioTracks = Self.planAudioTracks(for: info.dash)

        // 添加所有 CDN 节点的 URL，让 AVPlayer 自动选择最快的
        // 这样可以解决单个 CDN 节点速度慢的问题
        for video in videos {
            for url in video.playableURLs {
                addVideoPlayBackInfo(info: video, url: url, duration: info.dash.duration)
            }
        }

        for track in audioTracks {
            addAudioPlayBackInfo(plan: track, duration: info.dash.duration)
        }

        if hasSubtitle || transportMode != .direct {
            // 只使用当前实例的 Server，不为媒体另建监听器；限制 loopback，动态端口。
            httpServer.listenAddressIPv4 = "127.0.0.1"
            do {
                try httpServer.start(0, forceIPv4: true)
                bindHttpServer()
                httpPort = (try? httpServer.port()) ?? 0
                // 注册当前会话的媒体流及其 CDN 候选（播放列表生成时用本地 URL）。
                if transportMode != .direct, httpPort > 0 {
                    registerProxyMedia(aid: aid)
                    proxyAvailable = true
                }
            } catch {
                // 监听器启动失败则保持原来的直连模式
                Logger.warn("media proxy http server failed, fallback direct: \(error)")
                proxyAvailable = false
            }
        }
        for subtitle in validSubtitles {
            if let url = subtitle.url {
                addSubtitleData(lang: subtitle.lan, name: subtitle.lan_doc, duration: info.dash.duration, url: url.absoluteString)
            }
        }

        // i-frame
        if let video = videos.last, let url = video.playableURLs.first {
            let media = """
            #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=\(Self.peakBandwidth(forAverage: video.bandwidth)),RESOLUTION=\(video.width ?? 0)x\(video.height ?? 0),URI="\(URLs.customDashPrefix)\(videoInfo.count)"

            """
            masterPlaylist.append(media)
            videoInfo.append(PlaybackInfo(info: video, urls: [url], duration: info.dash.duration))
        }

        masterPlaylist.append("\n#EXT-X-ENDLIST\n")

        // 清单里带签名 CDN URL：只在 DEBUG 输出，Release 不把 token/签名写进可导出的日志文件。
        #if DEBUG
            Logger.debug("masterPlaylist: \(masterPlaylist)")
        #else
            Logger.info("masterPlaylist built: variants=\(videoInfo.count) chars=\(masterPlaylist.count)")
        #endif
    }

    func prewarmPrimaryVideoIndex() async {
        guard let firstVideo = videoInfo.first else { return }
        _ = await segmentInfoCache.sidx(from: firstVideo.info, preferredHost: preferredHost)
    }

    private func reportError(_ loadingRequest: AVAssetResourceLoadingRequest, withErrorCode error: Int) {
        loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: error, userInfo: nil))
    }

    private func report(_ loadingRequest: AVAssetResourceLoadingRequest, content: String) {
        if let data = content.data(using: .utf8) {
            loadingRequest.dataRequest?.respond(with: data)
            loadingRequest.finishLoading()
        } else {
            reportError(loadingRequest, withErrorCode: badRequestErrorCode)
        }
    }

    func resourceLoader(_: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool
    {
        guard let scheme = loadingRequest.request.url?.scheme, scheme == URLs.customScheme else {
            return false
        }

        // 直接在 loader 串行队列处理，避免被主线程（弹幕渲染等）阻塞。
        // playlist 相关状态在 setBilibili 中写入且发生在 setDelegate 之前，此处只读，无竞争。
        handleCustomPlaylistRequest(loadingRequest)
        return true
    }
}

private extension BilibiliVideoResourceLoaderDelegate {
    func handleCustomPlaylistRequest(_ loadingRequest: AVAssetResourceLoadingRequest) {
        guard let customUrl = loadingRequest.request.url else {
            reportError(loadingRequest, withErrorCode: badRequestErrorCode)
            return
        }
        let urlStr = customUrl.absoluteString
        Logger.debug("handleCustomPlaylistRequest: \(urlStr)")
        if urlStr == URLs.play {
            report(loadingRequest, content: masterPlaylist)
            return
        }

        if urlStr.hasPrefix(URLs.customPrefix), let index = Int(customUrl.lastPathComponent) {
            // 压制 tvOS 在**暂停 / 回看**时的自动选轨。
            //
            // 实测证据（真机 /debug/log）：播放中途 17:14:33 出现 atv://list/0 请求并拉走字幕片段，
            // 而当时既没有换 item、也没有 resume，App 侧没有任何选轨调用（选轨只有三处：
            // 换 item、起播/恢复、手动点菜单），设备上 subtitleAutoSelect=false、preferLan 为空
            // —— 是 AVKit 自己挑了一条轨拉起来显示（Apple TV 上"回看自动弹字幕"的同一套行为）。
            // 这种系统行为无法用 AVMediaSelection 关掉，只能在数据层让它无内容可显示。
            //
            // 只放行用户在菜单里明确选中的那条轨；其余一律回空清单。
            let wanted = Self.wantedSubtitleLan(autoSelect: Settings.subtitleAutoSelect,
                                                preferLan: Settings.subtitlePreferLan)
            let wantedLan = wanted.flatMap {
                Self.resolvedSubtitleLan(preference: $0, availableLans: subtitleLans)
            }
            guard subtitleLans.indices.contains(index), playlists.indices.contains(index) else {
                Logger.warn("[subtitle] 越界清单请求 index=\(index) count=\(subtitleLans.count)")
                reportError(loadingRequest, withErrorCode: badRequestErrorCode)
                return
            }
            if subtitleLans[index] != wantedLan {
                Logger.debug("[subtitle] 拦截非用户所选轨道的清单请求: \(subtitleLans[index])（wanted=\(wantedLan ?? "nil")）")
                report(loadingRequest, content: Self.emptySubtitlePlaylist)
                return
            }
            report(loadingRequest, content: playlists[index])
            return
        }
        if urlStr.hasPrefix(URLs.customDashPrefix), let index = Int(customUrl.lastPathComponent) {
            guard videoInfo.indices.contains(index) else {
                Logger.warn("[dash] 越界清单请求 index=\(index) count=\(videoInfo.count)")
                reportError(loadingRequest, withErrorCode: badRequestErrorCode)
                return
            }
            let info = videoInfo[index]
            Task {
                report(loadingRequest, content: await getVideoPlayList(info: info))
            }
        }
        if urlStr.hasPrefix(URLs.customSubtitlePrefix) {
            let url = String(urlStr.dropFirst(URLs.customSubtitlePrefix.count))
            let req = url.removingPercentEncoding ?? url
            guard let subtitleURL = URL(string: req) else {
                loadingRequest.finishLoading(with: URLError(.badURL))
                return
            }
            Task {
                do {
                    if !hasSubtitleVTT(for: req) {
                        let content = try await WebRequest.requestSubtitle(url: subtitleURL)
                        let vtt = BVideoUrlUtils.convertToVTT(subtitle: content)
                        storeSubtitleVTT(vtt, for: req)
                    }
                    let port = try self.httpServer.port()
                    let redirectURLString = "http://127.0.0.1:\(port)/subtitle?u=" + url
                    guard let redirectURL = URL(string: redirectURLString) else {
                        throw URLError(.badURL)
                    }
                    let redirectRequest = URLRequest(url: redirectURL)
                    let redirectResponse = HTTPURLResponse(url: redirectURL, statusCode: 302, httpVersion: nil, headerFields: nil)

                    loadingRequest.redirect = redirectRequest
                    loadingRequest.response = redirectResponse
                    loadingRequest.finishLoading()
                    return
                } catch let err {
                    loadingRequest.finishLoading(with: err)
                }
            }
            return
        }
        Logger.debug("handle loading \(customUrl)")
    }

    func bindHttpServer() {
        httpServer["/subtitle"] = { [weak self] req in
            if let url = req.queryParams.first(where: { $0.0 == "u" })?.1 {
                let req = url.removingPercentEncoding ?? url
                if let content = self?.subtitleVTT(for: req) {
                    return HttpResponse.ok(.text(content))
                }
            }
            return HttpResponse.notFound()
        }
        // 只接受当前播放会话媒体标识的 /media/:id，不接受请求直接指定外部 URL，
        // 不将带签名的真实 CDN URL 编码到本地路径中。
        httpServer["/media/:id"] = { [weak self] req in
            guard let self else { return HttpResponse.internalServerError(nil) }
            return self.handleMediaProxyRequest(req)
        }
    }

    // MARK: - 本地媒体代理

    /// 解析 DASH segment_base.index_range（"start-end"），供信任锚点使用。
    private static func indexRange(_ media: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> MediaByteRange? {
        let parts = media.segment_base.index_range.components(separatedBy: "-")
        guard parts.count == 2,
              let start = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(parts[1].trimmingCharacters(in: .whitespaces)),
              let range = try? MediaByteRange(start: start, end: end)
        else { return nil }
        return range
    }

    /// 为当前会话已注册的媒体流生成本地 URL；未注册/不可用时返回 nil（调用方回退直连）。
    func mediaTransportURL(for media: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> String? {
        guard transportMode != .direct, proxyAvailable, httpPort > 0 else { return nil }
        guard let id = proxyRegistry.id(for: media) else { return nil }
        return "http://127.0.0.1:\(httpPort)/media/\(id)"
    }

    private func registerProxyMedia(aid: Int) {
        let referer = Keys.referer(for: aid)
        // 同一 DashMediaInfo 的多 CDN URL 共享同一媒体 ID；不同清晰度/codec/音视频轨道
        // 因 DashMediaInfo 不同而自然隔离，不会共用错误标识。
        var seen = Set<VideoPlayURLInfo.DashInfo.DashMediaInfo>()
        for entry in videoInfo {
            let media = entry.info
            guard seen.insert(media).inserted else { continue }
            let candidates = media.playableURLs
            guard !candidates.isEmpty else { continue }
            let mode: MediaTransportMode = transportMode == .accelerated ? .accelerated : .proxy
            let downloader = MediaRangeDownloader(candidates: candidates, referer: referer, mode: mode)
            proxyRegistry.register(media: media, candidates: candidates, referer: referer, downloader: downloader)
        }
    }

    /// Swifter 同步 handler（运行在后台连接队列，禁止阻塞主线程）。
    /// 响应头发送前完成元信息验证；206 发送后只允许补齐剩余字节或截断触发播放器级恢复。
    /// 注意：handler 只持有注册表的不可变元信息快照（锁内一次性拷贝），
    /// 不直接读取可变的 Entry，避免与 totalLength 更新竞争。
    private func handleMediaProxyRequest(_ req: HttpRequest) -> HttpResponse {
        guard let mediaID = req.params[":id"], !mediaID.isEmpty else {
            return HttpResponse.badRequest(nil)
        }
        guard let entry = proxyRegistry.snapshot(for: mediaID) else {
            return HttpResponse.notFound(nil)
        }
        let method = req.method.uppercased()
        if method == "HEAD" {
            // 返回与当前可用元信息一致的头，不传 body
            let headers = MediaRangeResponseHeaders.head(totalLength: entry.totalLength)
            return HttpResponse.raw(200, "OK", headers, nil)
        }
        guard method == "GET" else {
            return HttpResponse.badRequest(nil)
        }
        let rangeHeader = req.headers["range"]
        let parsed = MediaRangeParsing.parse(header: rangeHeader, fileLength: entry.totalLength)
        switch parsed {
        case .missing:
            // 无 Range 的整文件请求：307 重定向回原 CDN，不伪造 206。
            // 注意：Swifter 的 movedTemporarily 实际发送 307；AVPlayer 是否保留
            // Range 语义跟随跳转仍需真机验证（见验收 P2）。
            if let fallback = entry.candidates.first, URL(string: fallback) != nil {
                return HttpResponse.movedTemporarily(fallback)
            }
            return HttpResponse.badRequest(nil)
        case .multiUnsupported:
            let headers = MediaRangeResponseHeaders.rangeNotSatisfiable(totalLength: entry.totalLength)
            return HttpResponse.raw(416, "Range Not Satisfiable", headers, nil)
        case .invalid:
            return HttpResponse.badRequest(nil)
        case let .unsatisfiable(total):
            let headers = MediaRangeResponseHeaders.rangeNotSatisfiable(totalLength: total ?? entry.totalLength)
            return HttpResponse.raw(416, "Range Not Satisfiable", headers, nil)
        case .openEnded, .suffix:
            // 需 total 归一化；未知 total 时走直连重定向降级，不阻塞等待探测
            if let total = entry.totalLength {
                let normalized = MediaRangeParsing.normalizeUnbounded(parsed, fileLength: total)
                if case let .single(range) = normalized {
                    return serveVerifiedRange(range, entry: entry, mediaID: mediaID)
                }
                let headers = MediaRangeResponseHeaders.rangeNotSatisfiable(totalLength: total)
                return HttpResponse.raw(416, "Range Not Satisfiable", headers, nil)
            }
            if let fallback = entry.candidates.first {
                return HttpResponse.movedTemporarily(fallback)
            }
            return HttpResponse.badRequest(nil)
        case let .single(range):
            // 超出安全容量的请求降级直连（与下载器共用同一个上限，避免清单放行而下载器拒收）
            if range.length > MediaDownloadLimits.singleRequestMemoryCap {
                if let fallback = entry.candidates.first {
                    return HttpResponse.movedTemporarily(fallback)
                }
                return HttpResponse.badRequest(nil)
            }
            return serveVerifiedRange(range, entry: entry, mediaID: mediaID)
        }
    }

    private func serveVerifiedRange(_ range: MediaByteRange, entry: MediaProxyRegistry.MediaSnapshot, mediaID: String) -> HttpResponse {
        // 首次请求时 total 通常未知，按 RFC 以 * 声明；AVPlayer 在当前 HLS 链路
        // 是否接受 bytes start-end/* 仍需真机验证（见验收 P2）。后续请求复用已缓存的 total。
        let headers = MediaRangeResponseHeaders.partialContent(range: range, totalLength: entry.totalLength)
        let downloader = entry.downloader
        let candidates = entry.candidates
        weak var weakSelf = self
        return HttpResponse.raw(206, "Partial Content", headers) { writer in
            let pipe = MediaBytePipe()
            let streamTask = Task {
                await downloader.stream(range: range, to: pipe)
            }
            // 后台同步排空：不阻塞主线程或 URLSession 回调线程
            assert(!Thread.isMainThread, "media proxy writer must not run on main thread")
            do {
                while true {
                    let chunk: Data?
                    do {
                        chunk = try pipe.readSync(maxLength: 64 * 1024, timeout: 30)
                    } catch {
                        streamTask.cancel()
                        throw error
                    }
                    guard let chunk else { break }
                    do {
                        try writer.write(chunk)
                    } catch {
                        // 读取方关闭/超时/写入失败：立即取消生产者（幂等），截断连接
                        streamTask.cancel()
                        throw error
                    }
                }
            } catch {
                streamTask.cancel()
                // 206 已发送：不能改写状态码，只能截断；播放器级恢复由 BVideoPlayPlugin 触发
                throw error
            }
            // 成功交付后异步更新诊断与 total 缓存（不阻塞 writer）
            Task { [weakSelf, downloader, candidates, mediaID] in
                if let total = await downloader.knownTotal() {
                    weakSelf?.proxyRegistry.updateTotalLength(total, for: mediaID)
                }
                if let diag = await weakSelf?.buildAccelerationText(downloader: downloader) {
                    weakSelf?.updateAccelerationText(diag)
                }
                _ = candidates
            }
        }
    }

    private func buildAccelerationText(downloader: MediaRangeDownloader) async -> String {
        let diag = await downloader.diagnostics()
        let modeText: String
        switch diag.transportMode {
        case .direct: modeText = "direct"
        case .proxy: modeText = "proxy"
        case .accelerated: modeText = "accel"
        }
        // 不输出 URL 查询参数/签名/Cookie；Mbps 为估计聚合值，仅供参考
        return String(format: "accel mode:%@ hosts:%d est %.1fMbps sub:%d fail:%d retry:%d ratio:%.2f%@",
                      modeText, diag.activeHosts, diag.estimatedAggregateMbps,
                      diag.activeSubrequests, diag.failures, diag.retries,
                      diag.redundancyRatio,
                      diag.downgradedToDirect ? " downgraded" : "")
    }
}

/// 当前播放会话内的媒体代理注册表（同步线程安全）。
/// 媒体 ID 映射到当前会话已注册的媒体流及其 CDN 候选；不接受外部 URL，不跨会话共享。
/// 对外只提供不可变的元信息快照：totalLength 的写入（锁内）与读取（快照拷贝）
/// 不会竞争；downloader 自身是 actor，跨线程引用安全。
final class MediaProxyRegistry: @unchecked Sendable {
    /// 不可变的单次请求视图。downloader 为 actor 引用，可在 handler 线程使用；
    /// totalLength/candidates 为读取时刻的拷贝。
    struct MediaSnapshot {
        let candidates: [String]
        let referer: String
        let downloader: MediaRangeDownloader
        let totalLength: Int64?
    }

    private final class Entry {
        let candidates: [String]
        let referer: String
        let downloader: MediaRangeDownloader
        var totalLength: Int64?
        init(candidates: [String], referer: String, downloader: MediaRangeDownloader) {
            self.candidates = candidates
            self.referer = referer
            self.downloader = downloader
        }

        func snapshot() -> MediaSnapshot {
            MediaSnapshot(candidates: candidates, referer: referer,
                          downloader: downloader, totalLength: totalLength)
        }
    }

    private let lock = NSLock()
    private var entries = [String: Entry]()
    private var idByMedia = [VideoPlayURLInfo.DashInfo.DashMediaInfo: String]()

    func register(media: VideoPlayURLInfo.DashInfo.DashMediaInfo, candidates: [String], referer: String, downloader: MediaRangeDownloader) {
        lock.lock()
        defer { lock.unlock() }
        if idByMedia[media] != nil { return }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        idByMedia[media] = id
        entries[id] = Entry(candidates: candidates, referer: referer, downloader: downloader)
    }

    func id(for media: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return idByMedia[media]
    }

    /// 锁内一次性拷贝，后续读取不再触碰共享可变状态。
    func snapshot(for id: String) -> MediaSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.snapshot()
    }

    /// 取指定媒体的下载器引用（actor，跨线程使用安全），用于设置信任锚点等。
    func downloader(for media: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> MediaRangeDownloader? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = idByMedia[media] else { return nil }
        return entries[id]?.downloader
    }

    func updateTotalLength(_ total: Int64, for id: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[id]?.totalLength = total
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        idByMedia.removeAll()
        lock.unlock()
    }
}

actor SidxDownloader {
    struct SidxResult {
        let sidx: SidxParseUtil.Sidx
        let url: String
        /// 索引区间的原始字节（等价性验证的信任锚点，不参与播放数据）。
        let indexBytes: Data
    }

    /// 缓存键：流信息 + 期望 host。preferredHost 不参与判键会把一个播放器探测出的
    /// CDN 泄漏给另一个并发播放器(如画中画)，历史上因此被迫做实例级缓存
    private struct CacheKey: Hashable {
        let info: VideoPlayURLInfo.DashInfo.DashMediaInfo
        let preferredHost: String?
    }

    private enum CacheEntry {
        case inProgress(InFlight<SidxResult?, Never>)
        case ready(SidxResult)
    }

    // sidx 只有几 KB，用短超时的独立 Session，避免默认 60s 超时把起播卡死
    private static let session: Session = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        config.headers = HTTPHeaders(["User-Agent": Keys.userAgent])
        return Session(configuration: config)
    }()

    /// 进程级共享：delegate 在切画质/换源时会整体重建，实例级缓存会让同一流的 sidx 反复下载
    static let shared = SidxDownloader(maxEntries: 16)

    private let maxEntries: Int
    private var cache: [CacheKey: CacheEntry] = [:]
    private var accessOrder = LRUOrder<CacheKey>()

    init(maxEntries: Int = 16) {
        self.maxEntries = maxEntries
    }

    func sidx(from info: VideoPlayURLInfo.DashInfo.DashMediaInfo, preferredHost: String? = nil) async -> SidxResult? {
        let key = CacheKey(info: info, preferredHost: preferredHost)
        if let cached = cache[key] {
            accessOrder.touch(key)
            switch cached {
            case let .ready(sidx):
                Logger.debug("sidx cache hit \(info.id)")
                return sidx
            case let .inProgress(entry):
                Logger.debug("sidx cache wait \(info.id)")
                return await entry.task.value
            }
        }

        let entry = InFlight(task: Task<SidxResult?, Never> {
            guard !Task.isCancelled else { return nil }
            return await downloadSidx(info: info, preferredHost: preferredHost)
        })

        cache[key] = .inProgress(entry)
        accessOrder.touch(key)

        let sidx = await entry.task.value
        guard case let .inProgress(current) = cache[key],
              current.token == entry.token
        else {
            // 等待期间被 LRU 驱逐/令牌失配：缓存不再写，但**结果照常交付**——
            // 此前直接 return nil 会让调用方退化到「单大 URL 兜底清单」（无分段、无代理注册），
            // 切画质/并发流多时可构造出这次偶发退化。下载成功的结果没理由扔掉。
            Logger.debug("sidx entry evicted while in-flight \(info.id), deliver without caching")
            return sidx
        }
        if let sidx {
            cache[key] = .ready(sidx)
        } else {
            cache[key] = nil
            accessOrder.remove(key)
        }
        trimToCapacity()
        Logger.debug("get sidx \(info.id)")
        return sidx
    }

    private func elapsedMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private func trimToCapacity() {
        while cache.count > maxEntries, let oldest = accessOrder.popOldest() {
            if case let .inProgress(inFlight) = cache[oldest] {
                inFlight.task.cancel()
            }
            cache[oldest] = nil
        }
    }

    private func downloadSidx(info: VideoPlayURLInfo.DashInfo.DashMediaInfo, preferredHost: String? = nil) async -> SidxResult? {
        let range = info.segment_base.index_range
        var urls = info.playableURLs
        // sidx 只有几 KB，探测到的只是延迟不是吞吐；运行时如果发现当前 host 扛不住实际码率，
        // 由外部指定 preferredHost 时强制优先试这个 host
        if let preferredHost,
           let idx = urls.firstIndex(where: { $0.urlHost == preferredHost })
        {
            urls.insert(urls.remove(at: idx), at: 0)
        }
        for url in urls.prefix(3) {
            guard !Task.isCancelled else { return nil }
            let host = url.urlHost ?? url
            let start = Date()
            if let res = try? await Self.session.request(url,
                                                         headers: ["Range": "bytes=\(range)",
                                                                   "Referer": "https://www.bilibili.com/"])
                .serializingData().result.get(),
                !Task.isCancelled,
                let segment = SidxParseUtil.processIndexData(data: res),
                !segment.segments.isEmpty
            {
                Logger.info("sidx ok in \(elapsedMs(since: start))ms from \(host)")
                return SidxResult(sidx: segment, url: url, indexBytes: res)
            }
            Logger.warn("sidx download failed in \(elapsedMs(since: start))ms on \(host), try next url")
        }
        return nil
    }
}
