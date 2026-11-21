//
//  BilibiliVideoResourceLoaderDelegate.swift
//  MPEGDASHAVPlayerDemo
//
//  Created by yicheng on 2022/08/20.
//  Copyright © 2022 yicheng. All rights reserved.
//
//  AVPlayer 自定义资源加载器。本文件只保留:
//    会话状态 / 自定义 scheme 分发 / 字幕缓存 / setBilibili 装配入口 / 诊断文本。
//  按职责拆出的同目录文件:
//    · BilibiliVideoResourceLoaderDelegate+HLS.swift      清单声明纯函数（帧率/声道/杜比/音轨计划/字幕选轨）
//    · BilibiliVideoResourceLoaderDelegate+Playlist.swift 单条流与字幕清单的生成
//    · BilibiliVideoResourceLoaderDelegate+MediaProxy.swift 本地 HTTP 媒体代理（含字幕重定向）
//    · MediaProxyRegistry.swift                           媒体 id → 下载器 的会话内注册表
//    · SidxDownloader.swift                               sidx 索引探测（进程级 LRU 缓存）
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
    var masterPlaylist = ""
    /// 本次装配的音频 rendition 计划，顺序即优先级（第一条成为 DEFAULT=YES 的起播音轨）
    var audioTracks = [AudioTrackPlan]()

    let badRequestErrorCode = 455

    var playlists = [String]()
    /// 跨线程共享的字幕缓存（锁保护，见下方 sharedStateLock 说明）
    var _subtitles = [String: String]()
    var videoInfo = [PlaybackInfo]()
    // sidx 探测结果进程级共享，缓存键 = (流信息 + preferredHost)：
    // preferredHost 参与判键，不会把一个播放器选中的 CDN 泄漏给另一个并发播放器；
    // 同键的重复请求(切画质/换 host 往返)直接复用，免去重复下载
    let segmentInfoCache = SidxDownloader.shared
    var hasAudioInMasterListAdded = false
    var hasSubtitle = false
    /// 与 `playlists` 一一对应的字幕轨 lan（原始值，未剥 ai- 前缀），用于判断"这条轨该不该给内容"
    var subtitleLans = [String]()
    /// 拦截日志合并：AVKit 曾在一秒内对同一条字幕清单发起上千次请求，
    /// 逐条打日志本身会把这台机器拖慢；每秒最多留一条并附上被压掉的次数。
    let subtitleInterceptLogLock = NSLock()
    var lastSubtitleInterceptLogTime: CFAbsoluteTime = 0
    var suppressedSubtitleInterceptCount = 0

    /// 空字幕清单：结构完全合法，只是没有任何 cue。用于压制系统的自动选轨，见
    /// `handleCustomPlaylistRequest` 里 atv://list/N 分支的说明。
    static let emptySubtitlePlaylist = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:1
    #EXT-X-MEDIA-SEQUENCE:0
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-ENDLIST

    """

    /// 被拦截的字幕清单回一个「带 1 秒空 WebVTT 分片」的合法 VOD。
    /// 零分片清单会让 AVKit 认为清单尚未就绪而密集重试（实测 1.8s 内 2564 次请求），
    /// 给一个可解析的空分片后它才会把这条轨当作已加载完成。
    func emptySubtitlePlaylistForIntercept() -> String {
        guard httpPort > 0 else { return Self.emptySubtitlePlaylist }
        return """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:1.0,

        http://127.0.0.1:\(httpPort)/empty.vtt
        #EXT-X-ENDLIST

        """
    }

    func logSubtitleIntercept(lan: String?, wanted: String?) {
        let now = CFAbsoluteTimeGetCurrent()
        var suppressed = 0
        var shouldLog = false
        subtitleInterceptLogLock.lock()
        if now - lastSubtitleInterceptLogTime >= 1 {
            suppressed = suppressedSubtitleInterceptCount
            suppressedSubtitleInterceptCount = 0
            lastSubtitleInterceptLogTime = now
            shouldLog = true
        } else {
            suppressedSubtitleInterceptCount += 1
        }
        subtitleInterceptLogLock.unlock()
        guard shouldLog else { return }
        Logger.debug("[subtitle] 拦截非用户所选轨道的清单请求: \(lan ?? "?")（wanted=\(wanted ?? "nil")）suppressed=\(suppressed)")
    }

    var httpServer = HttpServer()
    var aid = 0
    var isHDR = false

    /// 跨线程共享状态同步层：这几个字段不满足 masterPlaylist/playlists 那套
    /// 「setDelegate 前写完、之后只读」的 happens-before 论证——
    /// subtitles 在资源加载 Task（全局并发执行器）写、Swifter HTTP 服务的 socket 线程读；
    /// currentSegmentHost 在 getVideoPlayList 的后台 Task 写、主线程诊断定时器（每 5s）读；
    /// cdnCandidates / primaryVideoBandwidth 在装配期写、播放器插件主线程读。
    /// 统一一把 NSLock 收口；锁内只有赋值/取值，无任何回调、IO 或字典重组之外的操作。
    let sharedStateLock = NSLock()
    var _cdnCandidates = [String]()
    var _primaryVideoBandwidth = 0
    var _currentSegmentHost: String?

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

    func setCdnDiagnostics(candidates: [String], primaryBandwidth: Int) {
        sharedStateLock.lock(); defer { sharedStateLock.unlock() }
        _cdnCandidates = candidates
        _primaryVideoBandwidth = primaryBandwidth
    }

    func setCurrentSegmentHost(_ host: String?) {
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
    var transportMode: MediaTransportMode = .direct
    /// 播放器实际生效的传输模式：代理启动失败时播放列表已回退直连 URI，
    /// 此时按 .direct 处理，避免错误进入加速恢复流程。
    var effectiveTransportMode: MediaTransportMode {
        transportMode == .direct ? .direct : (proxyAvailable ? transportMode : .direct)
    }

    /// 本地代理是否可用（服务器启动成功且已注册媒体）。不可用时播放列表回退直连。
    var proxyAvailable = false
    /// 本地代理监听端口（0 表示未启动）。生成媒体播放列表时用它拼接本地 URL。
    var httpPort = 0
    /// 媒体代理注册表（线程安全，Swifter 同步 handler 与播放列表生成并发访问）。
    let proxyRegistry = MediaProxyRegistry()
    let diagLock = NSLock()
    var _accelerationText = ""
    /// 播放中途检测到当前 host 吞吐撑不住时，外部（BVideoPlayPlugin）指定的优先 host，
    /// sidx 探测会把它排到候选队首，覆盖默认 URL 顺序
    var preferredHost: String?
    deinit {
        httpServer.stop()
    }

    /// 加速诊断文本（同步读取，供 DebugPlugin 展示；敏感签名已剔除）。
    var accelerationDebugInfo: String {
        diagLock.lock()
        defer { diagLock.unlock() }
        return _accelerationText
    }

    func updateAccelerationText(_ text: String) {
        diagLock.lock()
        _accelerationText = text
        diagLock.unlock()
    }

    func reset() {
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

    func reportError(_ loadingRequest: AVAssetResourceLoadingRequest, withErrorCode error: Int) {
        loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: error, userInfo: nil))
    }

    func report(_ loadingRequest: AVAssetResourceLoadingRequest, content: String) {
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
