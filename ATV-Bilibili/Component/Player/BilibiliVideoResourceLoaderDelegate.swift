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
        let url: String
        let duration: Int
    }

    /// 音轨计划。必须先生成、再写视频 variant：variant 的 CODECS 要带上音频编码，
    /// 而 master playlist 只被 AVPlayer 读一次，写完视频条目就无法回头补。
    struct AudioTrackPlan {
        let info: VideoPlayURLInfo.DashInfo.DashMediaInfo
        let url: String
        /// 音轨在播放器音频菜单里的名字，按来源区分（杜比/无损/立体声）
        let label: String
    }

    private var audioPlaylist = ""
    private var videoPlaylist = ""
    private var backupVideoPlaylist = ""
    /// 已生成的 master playlist。播放期它只被 AVPlayer 读一次，
    /// 这里放开内部读权限，供单测断言清单结构（音轨声道数/编码/帧率等声明）。
    private(set) var masterPlaylist = ""
    /// 本次装配的音频 rendition 计划，顺序即优先级（第一条成为 DEFAULT=YES 的起播音轨）
    private var audioTracks = [AudioTrackPlan]()

    private let badRequestErrorCode = 455

    private var playlists = [String]()
    private var subtitles = [String: String]()
    private var videoInfo = [PlaybackInfo]()
    // sidx 探测结果进程级共享，缓存键 = (流信息 + preferredHost)：
    // preferredHost 参与判键，不会把一个播放器选中的 CDN 泄漏给另一个并发播放器；
    // 同键的重复请求(切画质/换 host 往返)直接复用，免去重复下载
    private let segmentInfoCache = SidxDownloader.shared
    private var hasAudioInMasterListAdded = false
    private var hasSubtitle = false
    private var hasPreferSubtitleAdded = false
    private var httpServer = HttpServer()
    private var aid = 0
    private(set) var isHDR = false
    /// 首选视频流的全部 CDN 候选，按 host 去重，供 CDNDiagnostics 实测
    private(set) var cdnCandidates = [String]()
    /// 首选视频流的声明带宽（bps），access log 的 indicatedBitrate 尚未就绪时作健康检测兜底
    private(set) var primaryVideoBandwidth = 0
    /// 最近一次生成媒体播放列表时实际选用的分片 host
    private(set) var currentSegmentHost: String?
    /// 播放中途检测到当前 host 吞吐撑不住时，外部（BVideoPlayPlugin）指定的优先 host，
    /// sidx 探测会把它排到候选队首，覆盖默认 URL 顺序
    private var preferredHost: String?
    deinit {
        httpServer.stop()
    }

    private func reset() {
        playlists.removeAll()
        audioTracks.removeAll()
        hasAudioInMasterListAdded = false
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
    private static func peakBandwidth(forAverage average: Int) -> Int {
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

    /// 规划音频 rendition。顺序即优先级：第一条被写成 DEFAULT=YES，成为起播音轨。
    /// 之前只用码率命名（"音轨 (448kbps)"），用户无从分辨杜比全景声 / 无损 / 立体声，
    /// 而这三种来源本来就是已知的。
    static func planAudioTracks(for dash: VideoPlayURLInfo.DashInfo,
                                includeLossless: Bool = Settings.losslessAudio) -> [AudioTrackPlan]
    {
        var plans = [AudioTrackPlan]()
        if includeLossless {
            if let dolby = dash.dolby?.audio?.max(by: { $0.bandwidth < $1.bandwidth }),
               let url = dolby.playableURLs.first
            {
                plans.append(AudioTrackPlan(info: dolby,
                                            url: url,
                                            label: "杜比全景声 (\(dolby.codecs), \(dolby.bandwidth / 1000)kbps)"))
            } else if let flac = dash.flac?.audio,
                      let url = flac.playableURLs.first
            {
                plans.append(AudioTrackPlan(info: flac,
                                            url: url,
                                            label: "Hi-Res 无损 (\(flac.bandwidth / 1000)kbps)"))
            }
        }
        // 普通音轨取码率最高的一条。B 站 dash.audio 的数组顺序并不固定
        // （实测同一视频两次请求分别为 [30232,30280,30216] 与 [30232,30216,30280]），
        // 原先取 .first 会稳定拿到 132kbps 的中档，丢掉 30280(192k~302k) 的最高档。
        if let best = dash.audio?.max(by: { $0.bandwidth < $1.bandwidth }),
           let url = best.playableURLs.first
        {
            plans.append(AudioTrackPlan(info: best,
                                        url: url,
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
        var videoRange = isHDR ? "HLG" : "SDR"
        var codecs = info.codecs
        var supplementCodesc = ""
        // TODO: Need update all codecs with https://developer.apple.com/documentation/http_live_streaming/http_live_streaming_hls_authoring_specification_for_apple_devices/hls_authoring_specification_for_apple_devices_appendixes
        let framerate = Self.hlsFrameRate(from: info.frame_rate)
        if isHDR10 {
            videoRange = "PQ"
        }
        if codecs == "dvh1.08.07" || codecs == "dvh1.08.03" {
            supplementCodesc = codecs + "/db4h"
            codecs = "hvc1.2.4.L153.b0"
            videoRange = "HLG"
        } else if codecs == "dvh1.08.06" {
            supplementCodesc = codecs + "/db1p"
            codecs = "hvc1.2.4.L150"
            videoRange = "PQ"
        } else if codecs.hasPrefix("dvh1.05") {
            videoRange = "PQ"
        } else if isHDR {
            Logger.warn("unknown hdr codecs: \(codecs)")
        }

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
        #EXT-X-STREAM-INF:\(leading)CODECS="\(masterCodecs)"\(supplementCodesc),RESOLUTION=\(info.width ?? 0)x\(info.height ?? 0),FRAME-RATE=\(framerate),BANDWIDTH=\(Self.peakBandwidth(forAverage: info.bandwidth)),AVERAGE-BANDWIDTH=\(info.bandwidth),VIDEO-RANGE=\(videoRange)
        \(URLs.customDashPrefix)\(videoInfo.count)?codec=\(info.codecs)&rate=\(info.frame_rate ?? framerate)&width=\(info.width ?? 0)&host=\(URL(string: url)?.host ?? "none")&range=\(info.id)

        """
        masterPlaylist.append(content)
        videoInfo.append(PlaybackInfo(info: info, url: url, duration: duration))
    }

    private func collectCDNCandidates(from video: VideoPlayURLInfo.DashInfo.DashMediaInfo?) {
        guard let video else {
            cdnCandidates = []
            primaryVideoBandwidth = 0
            return
        }
        primaryVideoBandwidth = video.bandwidth
        var seenHosts = Set<String>()
        cdnCandidates = video.playableURLs.filter { url in
            guard let host = URLComponents(string: url)?.host else { return false }
            return seenHosts.insert(host).inserted
        }

        let detail = cdnCandidates
            .map { url in
                let host = URLComponents(string: url)?.host ?? "?"
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
            currentSegmentHost = URLComponents(string: info.url)?.host
            return """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:\(info.duration)
            #EXT-X-MEDIA-SEQUENCE:1
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:\(info.duration)
            \(info.url)
            #EXT-X-ENDLIST
            """
        }

        // 使用 sidx 实际下载成功的 URL——它已经完成了对 CDN 可用性的探测，
        // 首选 CDN 挂掉时 segment 会整体切到探测成功的备用 URL
        let segment = sidxResult.sidx
        let segmentURL = sidxResult.url
        currentSegmentHost = URLComponents(string: segmentURL)?.host
        var playList = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(segment.maxSegmentDuration() ?? info.duration)
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="\(segmentURL)",BYTERANGE="\(moovIdx + 1)@\(moovOffset)"

        """
        offset += 1
        for segInfo in segment.segments {
            let segStr = """
            #EXTINF:\(Double(segInfo.duration) / Double(segment.timescale)),
            #EXT-X-BYTERANGE:\(segInfo.size)@\(offset)
            \(segmentURL)

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
        videoInfo.append(PlaybackInfo(info: plan.info, url: plan.url, duration: duration))
    }

    private func addSubtitleData(lang: String, name: String, duration: Int, url: String) {
        var lang = lang
        var canBeDefault = !hasPreferSubtitleAdded
        if lang.hasPrefix("ai-") {
            lang = String(lang.dropFirst(3))
            canBeDefault = false
        }
        if canBeDefault {
            hasPreferSubtitleAdded = true
        }
        let defaultStr = canBeDefault ? "YES" : "NO"

        let master = """
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="\(lang)",NAME="\(name)",AUTOSELECT=\(defaultStr),DEFAULT=\(defaultStr),URI="\(URLs.customPrefix)\(playlists.count)"

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

    func setBilibili(info: VideoPlayURLInfo, subtitles: [SubtitleData], aid: Int, maxQuality: Int? = nil, streamIndex: Int? = nil, preferredHost: String? = nil) {
        self.aid = aid
        self.preferredHost = preferredHost
        reset()
        hasSubtitle = subtitles.count > 0
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

        if hasSubtitle {
            try? httpServer.start(0)
            bindHttpServer()
        }
        for subtitle in subtitles {
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
            videoInfo.append(PlaybackInfo(info: video, url: url, duration: info.dash.duration))
        }

        masterPlaylist.append("\n#EXT-X-ENDLIST\n")

        Logger.debug("masterPlaylist: \(masterPlaylist)")
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
            let playlist = playlists[index]
            report(loadingRequest, content: playlist)
            return
        }
        if urlStr.hasPrefix(URLs.customDashPrefix), let index = Int(customUrl.lastPathComponent) {
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
                    if subtitles[req] == nil {
                        let content = try await WebRequest.requestSubtitle(url: subtitleURL)
                        let vtt = BVideoUrlUtils.convertToVTT(subtitle: content)
                        subtitles[req] = vtt
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
                if let content = self?.subtitles[req] {
                    return HttpResponse.ok(.text(content))
                }
            }
            return HttpResponse.notFound()
        }
    }
}

actor SidxDownloader {
    struct SidxResult {
        let sidx: SidxParseUtil.Sidx
        let url: String
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
            return nil
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
           let idx = urls.firstIndex(where: { URLComponents(string: $0)?.host == preferredHost })
        {
            urls.insert(urls.remove(at: idx), at: 0)
        }
        for url in urls.prefix(3) {
            guard !Task.isCancelled else { return nil }
            let host = URLComponents(string: url)?.host ?? url
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
                return SidxResult(sidx: segment, url: url)
            }
            Logger.warn("sidx download failed in \(elapsedMs(since: start))ms on \(host), try next url")
        }
        return nil
    }
}
