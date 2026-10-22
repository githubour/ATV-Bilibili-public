//
//  VideoPlayerViewModel.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2024/5/23.
//

import Combine
import UIKit

struct PlayerDetailData {
    let aid: Int
    let cid: Int
    let epid: Int? // 港澳台解锁需要
    let seasonId: Int? // 番剧 season_id
    let subType: Int? // 0: 普通视频 1：番剧 2：电影 3：纪录片 4：国创 5：电视剧 7：综艺

    var playerStartPos: Int?
    var detail: VideoDetail?
    var clips: [VideoPlayURLInfo.ClipInfo]?
    var playerInfo: PlayerInfo?
    var videoPlayURLInfo: VideoPlayURLInfo

    var isBangumi: Bool {
        return epid ?? 0 > 0 || seasonId ?? 0 > 0
    }
}

/// 播放数据装配的业务性失败（替代 throw String：调用方拿整段文案无法分支处理）
enum PlaybackError: LocalizedError {
    /// 番剧区域限制/大会员等 statusFail，需要按 code 区分展示
    case needVipAccess(code: Int, message: String)
    /// 充电专属视频
    case upowerExclusive(underlying: String)
    /// PlayInfo 解析出的 cid 缺失（如番剧 episodes 为空），此前会以 cid=0 继续请求
    case missingCid

    var errorDescription: String? {
        switch self {
        case let .needVipAccess(code, message):
            return "\(code) \(message)，可能需要大会员"
        case let .upowerExclusive(underlying):
            return "该视频为充电专属视频 \(underlying)"
        case .missingCid:
            return "视频分P信息异常（cid 缺失），请尝试重新进入"
        }
    }
}

@MainActor
class VideoPlayerViewModel {
    let loadResult = PassthroughSubject<Result<[CommonPlayerPlugin], String>, Never>()
    var onExit: (() -> Void)?
    var onPlayInfoChanged: ((PlayInfo) -> Void)?
    var onShowDetail: ((PlayInfo) -> Void)?
    var sequenceProvider: VideoSequenceProvider?
    /// 自动连播方向，由外层在 present 前设置，决定播完一条后往前还是往后走
    var sequenceDirection: SequencePlayDirection = .forward

    private var playInfo: PlayInfo
    private let playMode: VideoPlayerMode
    /// 隐身播放：本次播放不写入观看历史（只影响 BVideoPlayPlugin 的心跳上报）
    private let isIncognito: Bool
    private let playContextCache: PlayContextCache?
    private let mediaWarmupManager: PlayerMediaWarmupManager?
    private let previewMuted: Bool
    private let startTimeOverride: Int?
    private let startTimeOverrideContentIdentity: String
    /// 详情页已经拿到的 detail/playerInfo：起播时直接复用，省两次重复请求。
    /// 只对创建时的 aid/cid 生效，连播切集后不能拿旧条目的 playerInfo。
    private var seededPlayerInfo: PlayerInfo?
    private let seededPlayerInfoAid: Int
    private let seededPlayerInfoCid: Int
    private var videoDetail: VideoDetail?
    /// 插件订阅，随每次重新加载（切集 / 重试）一起重建
    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    init(playInfo: PlayInfo,
         playMode: VideoPlayerMode = .regular,
         isIncognito: Bool = false,
         playContextCache: PlayContextCache? = nil,
         mediaWarmupManager: PlayerMediaWarmupManager? = nil,
         previewMuted: Bool = true,
         startTimeOverride: Int? = nil,
         initialDetail: VideoDetail? = nil,
         initialPlayerInfo: PlayerInfo? = nil)
    {
        self.playInfo = playInfo
        self.playMode = playMode
        self.isIncognito = isIncognito
        self.playContextCache = playContextCache
        self.mediaWarmupManager = mediaWarmupManager
        self.previewMuted = previewMuted
        self.startTimeOverride = startTimeOverride
        startTimeOverrideContentIdentity = playInfo.contentIdentity
        videoDetail = initialDetail
        seededPlayerInfo = initialPlayerInfo
        seededPlayerInfoAid = playInfo.aid
        seededPlayerInfoCid = playInfo.cid ?? 0
    }

    var currentPlayInfo: PlayInfo {
        playInfo
    }

    func load() {
        startLoad(for: playInfo)
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
    }

    private func startLoad(for requestedPlayInfo: PlayInfo) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await performLoad(for: requestedPlayInfo, generation: generation)
        }
        loadTask = task
    }

    private func performLoad(for requestedPlayInfo: PlayInfo, generation: Int) async {
        defer {
            if loadGeneration == generation {
                loadTask = nil
            }
        }
        do {
            let (resolvedPlayInfo, data) = try await loadVideoInfo(for: requestedPlayInfo)
            guard !Task.isCancelled, loadGeneration == generation else { return }

            let danmakuProvider = VideoDanmakuProvider(enableDanmakuFilter: Settings.enableDanmakuFilter,
                                                       enableDanmakuRemoveDup: Settings.enableDanmakuRemoveDup)
            // 弹幕是增强信息，不应挡住起播：先装配插件、加载媒体，弹幕在后台补齐。
            // initVideo 内部按 cid 拉两路接口，弱网/接口慢时旧写法会让黑屏多等数秒。
            Task { await danmakuProvider.initVideo(cid: data.cid, startPos: data.playerStartPos ?? 0) }
            guard !Task.isCancelled, loadGeneration == generation else { return }

            playInfo = resolvedPlayInfo
            videoDetail = data.detail
            cancellables.removeAll()
            let plugins = generatePlayerPlugin(data,
                                               playInfo: resolvedPlayInfo,
                                               danmakuProvider: danmakuProvider)
            guard !Task.isCancelled, loadGeneration == generation else { return }
            loadResult.send(.success(plugins))
        } catch is CancellationError {
            return
        } catch let err {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            loadResult.send(.failure(err.localizedDescription))
        }
    }

    private func loadVideoInfo(for playInfo: PlayInfo) async throws -> (PlayInfo, PlayerDetailData) {
        let resolvedPlayInfo = try await PlayInfoResolver.resolve(playInfo)
        try Task.checkCancellation()
        let data = try await fetchVideoData(for: resolvedPlayInfo)
        try Task.checkCancellation()
        return (resolvedPlayInfo, data)
    }

    private func fetchVideoDetail(aid: Int, existing: VideoDetail?) async -> VideoDetail? {
        if let existing { return existing }
        return try? await WebRequest.requestDetailVideo(aid: aid)
    }

    /// 起播用的 playerInfo：详情页已传入就直接复用，否则才发请求。
    private func playerInfoForLoad(aid: Int, cid: Int) async -> PlayerInfo? {
        if aid == seededPlayerInfoAid, cid == seededPlayerInfoCid, let seeded = seededPlayerInfo {
            seededPlayerInfo = nil
            return seeded
        }
        return try? await WebRequest.requestPlayerInfo(aid: aid, cid: cid)
    }

    private func fetchVideoData(for playInfo: PlayInfo) async throws -> PlayerDetailData {
        // assert 只在 Debug 生效；cid 缺失的脏 PlayInfo 必须在入口拒绝，
        // 否则拿着 cid=0 继续请求 playerInfo 得到一串无意义结果
        guard let cid = playInfo.cid, cid > 0 else { throw PlaybackError.missingCid }
        let existingVideoDetail = videoDetail?.View.aid == playInfo.aid ? videoDetail : nil
        if !playInfo.isBangumi, let playContextCache {
            let cached = try await playContextCache.context(for: playInfo, mode: playContextMode)
            let resolvedDetail = cached.detail ?? existingVideoDetail

            var detail = PlayerDetailData(aid: playInfo.aid,
                                          cid: cached.cid,
                                          epid: playInfo.epid,
                                          seasonId: playInfo.seasonId,
                                          subType: playInfo.subType,
                                          detail: resolvedDetail,
                                          clips: nil,
                                          playerInfo: cached.playerInfo,
                                          videoPlayURLInfo: cached.videoPlayURLInfo)

            let lastPlayCid = playInfo.lastPlayCid ?? cached.playerInfo?.last_play_cid ?? 0
            let playTimeInSecond = playInfo.playTimeInSecond ?? cached.playerInfo?.playTimeInSecond ?? 0
            detail.playerStartPos = resolvedPlayerStartPos(cid: cached.cid,
                                                           duration: cached.videoPlayURLInfo.dash.duration,
                                                           lastPlayCid: lastPlayCid,
                                                           playTimeInSecond: playTimeInSecond,
                                                           playInfo: playInfo)
            return detail
        }

        let aid = playInfo.aid
        async let infoReq = playerInfoForLoad(aid: aid, cid: cid)
        async let detailReq = fetchVideoDetail(aid: aid, existing: existingVideoDetail)
        do {
            let playData: VideoPlayURLInfo
            var clipInfos: [VideoPlayURLInfo.ClipInfo]?

            if playInfo.isBangumi {
                do {
                    playData = try await WebRequest.requestPcgPlayUrl(aid: aid, cid: cid, options: playContextMode.requestOptions)
                } catch let err as RequestError {
                    if case let .statusFail(code, _) = err,
                       code == -404 || code == -10403,
                       let data = try await fetchAreaLimitPcgVideoData(for: playInfo)
                    {
                        playData = data
                    } else {
                        throw err
                    }
                }

                clipInfos = playData.clip_info_list
            } else {
                playData = try await WebRequest.requestPlayUrl(aid: aid, cid: cid, options: playContextMode.requestOptions)
            }

            let info = await infoReq
            let resolvedDetail = await detailReq

            var detail = PlayerDetailData(aid: playInfo.aid, cid: cid, epid: playInfo.epid, seasonId: playInfo.seasonId, subType: playInfo.subType, detail: resolvedDetail, clips: clipInfos, playerInfo: info, videoPlayURLInfo: playData)

            let last_play_cid = playInfo.lastPlayCid ?? info?.last_play_cid ?? 0
            let playTimeInSecond = playInfo.playTimeInSecond ?? info?.playTimeInSecond ?? 0
            detail.playerStartPos = resolvedPlayerStartPos(cid: cid,
                                                           duration: playData.dash.duration,
                                                           lastPlayCid: last_play_cid,
                                                           playTimeInSecond: playTimeInSecond,
                                                           playInfo: playInfo)

            return detail

        } catch let err {
            if case let .statusFail(code, message) = err as? RequestError {
                throw PlaybackError.needVipAccess(code: code, message: message)
            } else if await infoReq?.is_upower_exclusive == true {
                throw PlaybackError.upowerExclusive(underlying: String(describing: err))
            } else {
                throw err
            }
        }
    }

    private func updatePlayInfo(_ newPlayInfo: PlayInfo) {
        playInfo = newPlayInfo
        onPlayInfoChanged?(newPlayInfo)
        startLoad(for: newPlayInfo)
    }

    private func resolvedPlayerStartPos(cid: Int,
                                        duration: Int,
                                        lastPlayCid: Int,
                                        playTimeInSecond: Int,
                                        playInfo: PlayInfo) -> Int?
    {
        if let startTimeOverride,
           startTimeOverrideContentIdentity == playInfo.contentIdentity,
           duration - startTimeOverride > 5
        {
            return startTimeOverride
        }
        if lastPlayCid == cid,
           duration - playTimeInSecond > 5,
           Settings.continuePlay
        {
            return playTimeInSecond
        }
        return nil
    }

    func retryCurrent() {
        load()
    }

    func playNextFromSequence() async -> Bool {
        guard let next = await sequenceProvider?.moveNext() else { return false }
        updatePlayInfo(next)
        return true
    }

    func playPreviousFromSequence() async -> Bool {
        guard let previous = sequenceProvider?.movePrevious() else { return false }
        updatePlayInfo(previous)
        return true
    }

    /// 选集面板直接跳到序列中的某一集。
    /// 走 setCurrentIndex + updatePlayInfo，不用 playTemporaryOverride——后者是"临时插播"
    /// 语义，会把这一集推进 temporaryOverrides 从而污染自动连播的顺序。
    func playEpisode(at index: Int) {
        guard let provider = sequenceProvider,
              provider.playSeq.indices.contains(index)
        else { return }
        provider.setCurrentIndex(index)
        updatePlayInfo(provider.playSeq[index])
    }

    func playTemporaryOverride(_ temporaryPlayInfo: PlayInfo) {
        guard temporaryPlayInfo.sequenceKey != currentPlayInfo.sequenceKey else { return }
        sequenceProvider.map { provider in
            MainActor.assumeIsolated {
                provider.pushTemporary(temporaryPlayInfo)
            }
        }
        updatePlayInfo(temporaryPlayInfo)
    }

    func preloadNeighborsIfNeeded() async {
        guard playMode == .feedFlow, let playContextCache, let sequenceProvider else { return }
        let current = sequenceProvider.current() ?? currentPlayInfo
        let priority = [current,
                        sequenceProvider.peekNext(),
                        sequenceProvider.peekPrevious()].compactMap { $0 }.uniqued()
        for info in priority {
            guard !Task.isCancelled else { return }
            await playContextCache.preload(playInfo: info, mode: .regular)
        }
        guard !Task.isCancelled else { return }
        await playContextCache.trim(keeping: priority)
        for info in priority {
            guard !Task.isCancelled else { return }
            await mediaWarmupManager?.preload(playInfo: info)
        }
    }

    private func generatePlayerPlugin(_ data: PlayerDetailData,
                                      playInfo: PlayInfo,
                                      danmakuProvider: VideoDanmakuProvider) -> [CommonPlayerPlugin]
    {
        let playplugin = BVideoPlayPlugin(playInfo: playInfo,
                                          detailData: data,
                                          reportWatchHistory: playMode != .preview && !isIncognito,
                                          minimizeStalling: true,
                                          isMuted: playMode == .preview && previewMuted,
                                          mediaWarmupManager: playMode == .feedFlow ? mediaWarmupManager : nil)
        playplugin.onLoadFailure = { [weak self] message in
            self?.loadResult.send(.failure(message))
        }

        if playMode == .preview {
            return [playplugin]
        }

        let danmaku = DanmakuViewPlugin(provider: danmakuProvider)
        let upnp = BUpnpPlugin(duration: data.detail?.View.duration)
        let debug = DebugPlugin()
        debug.additionDebugInfo = { [weak playplugin] in
            playplugin?.networkDebugInfo ?? ""
        }
        let playSpeed = SpeedChangerPlugin()
        playSpeed.$currentPlaySpeed.sink { [weak danmaku] speed in
            danmaku?.danmakuView.playingSpeed = speed.value
        }.store(in: &cancellables)

        let playlist = VideoPlayListPlugin(sequenceProvider: sequenceProvider)
        playlist.isReversed = sequenceDirection == .reverse
        playlist.onPlayEnd = { [weak self] in
            guard let self, self.playMode != .preview else { return }
            self.onExit?()
        }
        playlist.onPlayNextWithInfo = {
            [weak self] info in
            guard let self else { return }
            updatePlayInfo(info)
        }
        playlist.onShowCurrentDetail = { [weak self] info in
            self?.onShowDetail?(info)
        }

        // SpeedChangerPlugin creates the shared settings menu that later plugins extend.
        // 片头片尾插件（「更多设置」齿轮菜单）必须紧随其后、排在 CDN 测速/Debug/播放列表之前：
        // 后三者的条目要挂进它的 .moreMenu 菜单（菜单按插件顺序构建，挂载点须先创建）
        let introOutro: CommonPlayerPlugin? = playMode == .preview ? nil : IntroOutroSkipPlugin(playInfo: playInfo)
        var plugins: [CommonPlayerPlugin] = [playSpeed, playplugin, danmaku, upnp, debug, playlist, SleepTimerPlugin()]
        if let introOutro {
            plugins.insert(introOutro, at: 1)
        }

        if !data.isBangumi, let detail = data.detail {
            let infoTabs = VideoPlayerInfoTabsPlugin(detail: detail,
                                                     currentPlayInfo: playInfo,
                                                     sequenceProvider: sequenceProvider)
            infoTabs.onSelectDiscovery = { [weak self] info in
                self?.playTemporaryOverride(info)
            }
            plugins.append(infoTabs)
        }

        // 添加画质选择器插件
        let qualitySelector = BVideoQualityPlugin(detailData: data) { [weak playplugin] qualityId, streamIndex in
            await playplugin?.switchQuality(to: qualityId, streamIndex: streamIndex) ?? false
        }

        plugins.append(qualitySelector)

        plugins.append(AISummaryPlugin(aid: playInfo.aid, cid: data.cid))

        let allSubtitles = data.playerInfo?.subtitle?.subtitles ?? []
        let subtitleTracks = allSubtitles.filter { $0.url != nil }
        // 拿得到轨道却被 url 过滤掉说明地址异常，记一条日志便于区分"视频没字幕"和"字幕取到了用不了"
        if allSubtitles.count != subtitleTracks.count {
            Logger.warn("[subtitle] \(allSubtitles.count) 条字幕中 \(allSubtitles.count - subtitleTracks.count) 条地址无效")
        }
        if !subtitleTracks.isEmpty {
            plugins.append(SubtitlePlugin(tracks: subtitleTracks))
        }

        if let clips = data.clips {
            let clip = BVideoClipsPlugin(clipInfos: clips)
            plugins.append(clip)
        }

        if Settings.enableSponsorBlock != .none, let bvid = data.detail?.View.bvid, let duration = data.detail?.View.duration {
            let sponsor = SponsorSkipPlugin(bvid: bvid, duration: duration)
            plugins.append(sponsor)
        }

        // iPhone 遥控的 ±15s 跳过按钮依赖完整 Now Playing 会话 (见 NowPlayingSessionPlugin)
        plugins.append(NowPlayingSessionPlugin())

        if playMode == .regular, let provider = sequenceProvider, provider.count > 1 {
            let entries = EpisodeEntry.build(from: provider.playSeq,
                                             isBangumi: data.isBangumi,
                                             coverURL: data.detail?.pic)
            let picker = EpisodePickerPlugin(entries: entries, currentIndex: provider.currentIndex)
            picker.onSelectEpisode = { [weak self] index in
                self?.playEpisode(at: index)
            }
            plugins.append(picker)
        }

        if Settings.danmakuMask {
            if let mask = data.playerInfo?.dm_mask,
               let video = data.videoPlayURLInfo.dash.video.first,
               mask.fps > 0
            {
                let maskProvider = BMaskProvider(info: mask, videoSize: CGSize(width: video.width ?? 0, height: video.height ?? 0))
                plugins.append(MaskViewPlugin(maskView: danmaku.danmakuView, maskProvider: maskProvider))
            } else if Settings.vnMask {
                let maskProvider = VMaskProvider()
                plugins.append(MaskViewPlugin(maskView: danmaku.danmakuView, maskProvider: maskProvider))
            }
        }

        // 默认视频标题作主标题 up主用户名作副标题
        if let detail = data.detail {
            var title = detail.title
            var subTitle = detail.ownerName
            // 分页播放时则以分页标题作主标题 up主用户名+视频标题作副标题
            let pages = detail.View.pages ?? []
            if pages.count > 1, let index = pages.firstIndex(where: { $0.cid == playInfo.cid }) {
                let page = pages[index]
                title = page.part
                subTitle += "·\(detail.title)"
            }
            let infoPlugin = BVideoInfoPlugin(title: title, subTitle: subTitle, desp: detail.View.desc, pic: detail.pic, viewPoints: data.playerInfo?.view_points)
            plugins.append(infoPlugin)
            Logger.debug("updateInfoPlugin: title: \(title) subTitle: \(subTitle)")
        }

        return plugins
    }

    private var playContextMode: PlayContextMode {
        switch playMode {
        case .preview:
            return .preview
        case .regular, .feedFlow:
            return .regular
        }
    }
}

// 港澳台解锁
extension VideoPlayerViewModel {
    private func fetchAreaLimitPcgVideoData(for playInfo: PlayInfo) async throws -> VideoPlayURLInfo? {
        guard Settings.areaLimitUnlock else { return nil }
        guard let epid = playInfo.epid, epid > 0 else { return nil }

        let season = try await WebRequest.requestBangumiSeasonView(epid: epid)
        let checkTitle = season.title.contains("僅") ? season.title : season.series_title
        let checkAreaList = parseAreaByTitle(title: checkTitle)
        guard !checkAreaList.isEmpty else { return nil }

        guard let cid = playInfo.cid, cid > 0 else { return nil }
        let playData = try await requestAreaLimitPcgPlayUrl(epid: epid, cid: cid, areaList: checkAreaList)
        return playData
    }

    private func requestAreaLimitPcgPlayUrl(epid: Int, cid: Int, areaList: [String]) async throws -> VideoPlayURLInfo? {
        for area in areaList {
            do {
                return try await WebRequest.requestAreaLimitPcgPlayUrl(epid: epid,
                                                                       cid: cid,
                                                                       area: area,
                                                                       options: playContextMode.requestOptions)
            } catch let err {
                if area == areaList.last {
                    throw err
                } else {
                    Logger.warn("[player] \(err)")
                }
            }
        }
        return nil
    }

    private func parseAreaByTitle(title: String) -> [String] {
        if title.isMatch(pattern: "(仅|僅).*(东南亚|其他)") {
            // 其他地区暂不支持
            return []
        }

        var areas: [String] = []
        if title.isMatch(pattern: "僅.*台") {
            areas.append("tw")
        }
        if title.isMatch(pattern: "僅.*港") {
            areas.append("hk")
        }

        if areas.isEmpty {
            // 标题没有地区限制信息，返回尝试检测的区域
            return ["tw", "hk"]
        } else {
            return areas
        }
    }
}
