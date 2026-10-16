//
//  BVideoPlayPlugin.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2024/5/24.
//

import AVKit
import UIKit

class BVideoPlayPlugin: NSObject, CommonPlayerPlugin {
    var onLoadFailure: ((String) -> Void)?

    private weak var playerVC: AVPlayerViewController?
    private var playerDelegate: BilibiliVideoResourceLoaderDelegate?
    private let playInfo: PlayInfo
    private let playData: PlayerDetailData
    private let reportWatchHistory: Bool
    private let minimizeStalling: Bool
    private let isMuted: Bool
    private let mediaWarmupManager: PlayerMediaWarmupManager?
    private var currentPlaybackTime: Double = 0
    // 记录最近一次实际用于加载的 maxQuality/streamIndex，host 切换时原样复用，
    // 不去动用户当前的画质模式（自动多档 fallback 还是手动锁定某一档）
    private var lastMaxQuality: Int?
    private var lastStreamIndex: Int?

    private var networkLogTimer: Timer?
    private var lastStalls = 0
    private var lastDroppedFrames = 0
    private var cdnProbeReport = ""
    private var isProbingCDN = false

    // 运行时 CDN 健康检测：只在真实卡顿时换 host，不用 observed/indicated 比特率比
    // （indicated 常是峰值 BANDWIDTH，播放流畅时 observed 低于它完全正常）
    private var stallUnhealthyStreak = 0
    private var isEvaluatingHostSwitch = false
    private var lastHostSwitchAt: Date?
    /// 连续几次处于卡顿/等待缓冲才触发，避免单次抖动
    private let stallTriggerCount = 2
    /// 换完 host 后的冷静期，避免连续误触发
    private let hostSwitchCooldown: TimeInterval = 30
    private let networkLogInterval: TimeInterval = 5
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    // ===== 编码格式故障自动切换 =====
    /// 起播看门狗：媒体装配完成后这么久仍未起播（出错/卡死/永远 buffering）视为超时
    private let startupTimeoutSeconds: TimeInterval = 20
    private var startupWatchdog: Timer?
    /// 已试败过的流（"画质id:编码"），防止在坏编码之间来回死循环
    private var failedStreamKeys = Set<String>()
    private var isCodecFailingOver = false
    /// 切编码冷静期，避免 item 报错与看门狗等触发源扎堆连切
    private let codecSwitchCooldown: TimeInterval = 10
    private var lastCodecSwitchAt: Date?

    init(playInfo: PlayInfo,
         detailData: PlayerDetailData,
         reportWatchHistory: Bool = true,
         minimizeStalling: Bool = true,
         isMuted: Bool = false,
         mediaWarmupManager: PlayerMediaWarmupManager? = nil)
    {
        self.playInfo = playInfo
        playData = detailData
        self.reportWatchHistory = reportWatchHistory
        self.minimizeStalling = minimizeStalling
        self.isMuted = isMuted
        self.mediaWarmupManager = mediaWarmupManager
    }

    deinit {
        networkLogTimer?.invalidate()
        startupWatchdog?.invalidate()
    }

    /// 供 DebugPlugin 浮层显示的网络诊断信息
    var networkDebugInfo: String {
        var lines = [String]()
        if let host = playerDelegate?.currentSegmentHost {
            lines.append("segment host: \(host)")
        }
        if !cdnProbeReport.isEmpty {
            lines.append(cdnProbeReport)
        }
        return lines.joined(separator: "\n")
    }

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
        playerVC.player = nil
        startLoad(urlInfo: playData.videoPlayURLInfo, playerInfo: playData.playerInfo)
    }

    func playerWillStart(player: AVPlayer) {
        if let playerStartPos = playData.playerStartPos {
            player.seek(to: CMTime(seconds: Double(playerStartPos), preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func playerDidStart(player _: AVPlayer) {
        disarmStartupWatchdog()
        startNetworkLogging()
    }

    func playerDidCleanUp(player: AVPlayer) {
        disarmStartupWatchdog()
        stopNetworkLogging()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// AVPlayerItem 进入 .failed：优先同画质换编码自救，候选耗尽再走原有失败呈现
    func playerDidFail(player: AVPlayer) {
        disarmStartupWatchdog()
        // 被换掉的旧 item 报错不作数
        guard player === playerVC?.player, player.currentItem?.status == .failed else { return }
        Task { @MainActor [weak self] in
            await self?.attemptCodecFailover(reason: "解码出错",
                                             fallbackMessage: "视频解码出错，且同画质下没有其他编码格式可切换")
        }
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        // 挂进「更多设置」齿轮菜单（依赖 IntroOutroSkipPlugin 先创建，未命中则丢弃）
        let action = UIAction(title: isProbingCDN ? "CDN 测速中…" : "CDN 测速",
                              image: UIImage(systemName: "speedometer"))
        { [weak self] _ in
            self?.probeCDN()
        }
        return insertIntoMenu([action], menu: .moreMenu, current: &current, fallbackToTopLevel: false)
    }

    private func probeCDN() {
        guard !isProbingCDN else { return }
        let candidates = playerDelegate?.cdnCandidates ?? []
        guard !candidates.isEmpty else {
            cdnProbeReport = "无候选 CDN"
            return
        }
        let currentHost = playerDelegate?.currentSegmentHost
        isProbingCDN = true
        cdnProbeReport = "CDN 测速中…"
        Task { @MainActor [weak self] in
            let report = await CDNDiagnostics.run(urls: candidates, currentHost: currentHost)
            self?.cdnProbeReport = report
            self?.isProbingCDN = false
        }
    }

    private func startNetworkLogging() {
        guard networkLogTimer == nil else { return }
        networkLogTimer = Timer.scheduledTimer(withTimeInterval: networkLogInterval, repeats: true) { [weak self] _ in
            self?.logNetworkStatus()
        }
    }

    private func stopNetworkLogging() {
        networkLogTimer?.invalidate()
        networkLogTimer = nil
    }

    private func logNetworkStatus() {
        guard let player = playerVC?.player,
              let item = player.currentItem,
              let event = item.accessLog()?.events.last
        else { return }
        // event.uri 是内部 variant playlist 的地址（我们用的是自定义 atv://dash/N scheme），
        // 解析出来的 host 恒为 "dash"，跟实际连的 CDN 无关；真实 host 记录在 playerDelegate 里。
        let host = playerDelegate?.currentSegmentHost ?? "-"
        let observedBps = event.observedBitrate
        let indicatedBps = event.indicatedBitrate
        let effectiveIndicated = effectiveIndicatedBitrate(from: indicatedBps)
        let observed = String(format: "%.1f", observedBps / 1_000_000)
        let indicated = String(format: "%.1f", indicatedBps / 1_000_000)
        let effective = String(format: "%.1f", effectiveIndicated / 1_000_000)
        let stalls = event.numberOfStalls
        let dropped = event.numberOfDroppedVideoFrames
        let tcs = player.timeControlStatus
        let waiting = player.reasonForWaitingToPlay?.rawValue ?? "-"
        let keepUp = item.isPlaybackLikelyToKeepUp
        let buffered = bufferedSeconds(of: item)
        let stallDelta = stalls - lastStalls
        Logger.info("playback host \(host) observed \(observed)Mbps indicated \(indicated)Mbps effective \(effective)Mbps stalls \(stalls)(+\(stallDelta)) dropped \(dropped)(+\(dropped - lastDroppedFrames)) serverChanges \(event.numberOfServerAddressChanges) tcs \(tcs.rawValue) wait \(waiting) keepUp \(keepUp) buffered \(String(format: "%.1f", buffered))s")
        lastStalls = stalls
        lastDroppedFrames = dropped

        checkStallHealth(stallDelta: stallDelta, buffered: buffered, currentHost: host)
    }

    /// 用户明确暂停（.paused）。卡缓冲/断网时是 .waitingToPlayAtSpecifiedRate，仍应做健康检测。
    private var isUserPaused: Bool {
        playerVC?.player?.timeControlStatus == .paused
    }

    private var isWaitingToPlay: Bool {
        playerVC?.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    /// access log 的 indicated 在起播/loading 时常为 0 或负值；日志里的 effective 用流声明平均带宽兜底。
    private func effectiveIndicatedBitrate(from accessLogIndicated: Double) -> Double {
        if accessLogIndicated > 0 { return accessLogIndicated }
        guard let declared = playerDelegate?.primaryVideoBandwidth, declared > 0 else { return 0 }
        return Double(declared)
    }

    private func bufferedSeconds(of item: AVPlayerItem) -> Double {
        guard let range = item.loadedTimeRanges.first?.timeRangeValue else { return 0 }
        let end = range.start.seconds + range.duration.seconds
        let current = item.currentTime().seconds
        guard end.isFinite, current.isFinite else { return 0 }
        return max(0, end - current)
    }

    /// 只根据真实卡顿触发换源：正在 waiting，或本周期新增了 stall。
    /// 播放流畅时仅 observed < indicated 不触发——indicated 常是峰值，低一些完全正常。
    private func checkStallHealth(stallDelta: Int, buffered: Double, currentHost: String) {
        guard !isUserPaused, !isEvaluatingHostSwitch else {
            stallUnhealthyStreak = 0
            return
        }
        if let lastSwitch = lastHostSwitchAt, Date().timeIntervalSince(lastSwitch) < hostSwitchCooldown {
            return
        }

        let unhealthy = isWaitingToPlay || stallDelta > 0
        if unhealthy {
            stallUnhealthyStreak += 1
        } else {
            stallUnhealthyStreak = 0
            return
        }
        guard stallUnhealthyStreak >= stallTriggerCount else { return }
        stallUnhealthyStreak = 0

        let requiredMbps = Double(playerDelegate?.primaryVideoBandwidth ?? 0) / 1_000_000
        Logger.info("[cdn] 检测到卡顿 (waiting=\(isWaitingToPlay), stallDelta=\(stallDelta), buffered \(String(format: "%.1f", buffered))s)，重新测速")
        Task { @MainActor [weak self] in
            await self?.evaluateHostSwitch(currentHost: currentHost, requiredMbps: requiredMbps)
        }
    }

    @MainActor
    private func evaluateHostSwitch(currentHost: String, requiredMbps: Double) async {
        guard !isEvaluatingHostSwitch else { return }
        guard !isUserPaused else { return }
        let candidates = playerDelegate?.cdnCandidates ?? []
        guard candidates.count > 1 else { return }
        isEvaluatingHostSwitch = true
        defer { isEvaluatingHostSwitch = false }

        Logger.info("[cdn] \(currentHost) 因卡顿重新测速 \(candidates.count) 个候选")
        let results = await CDNDiagnostics.probeAll(urls: candidates)
        // 测速是异步的，期间用户可能已手动暂停；换源会重建 AVPlayer，必须取消
        guard !isUserPaused else {
            Logger.info("[cdn] 用户已暂停，取消 host 切换")
            return
        }
        let ranked = results.filter { $0.mbps != nil }.sorted { ($0.mbps ?? -1) > ($1.mbps ?? -1) }
        guard !ranked.isEmpty else {
            Logger.info("[cdn] 候选测速全部失败，保持 \(currentHost)")
            return
        }

        // 优先更快的非当前节点；若短测速仍显示当前最快，则取第二名做强制尝试
        let alternate = ranked.first(where: { $0.host != currentHost })
        guard let target = alternate, let targetMbps = target.mbps else {
            Logger.info("[cdn] 没有其他可用候选，保持 \(currentHost)")
            return
        }
        if requiredMbps > 0, targetMbps < requiredMbps * 0.5 {
            Logger.info("[cdn] 备选 \(target.host) (\(String(format: "%.1f", targetMbps))Mbps) 远低于流码率，放弃切换")
            return
        }

        let currentMbps = ranked.first(where: { $0.host == currentHost })?.mbps
        let reason: String
        if let currentMbps, targetMbps > currentMbps * 1.3 {
            reason = "测速明显更快"
        } else if let currentMbps, targetMbps >= currentMbps * 0.7 {
            // 短测速乐观且接近时，当前节点已真实卡顿，强制换一个试试
            reason = "测速接近但已卡顿，强制尝试"
        } else if currentMbps == nil {
            reason = "当前节点测速失败"
        } else {
            Logger.info("[cdn] 备选 \(target.host) (\(String(format: "%.1f", targetMbps))Mbps) 明显慢于当前 \(currentHost) (\(String(format: "%.1f", currentMbps!))Mbps)，保持")
            return
        }

        lastHostSwitchAt = Date()
        Logger.info("[cdn] 切换 host: \(currentHost) -> \(target.host) (实测\(String(format: "%.1f", targetMbps))Mbps, \(reason))")
        await switchHost(to: target.host)
    }

    @MainActor
    private func switchHost(to host: String) async {
        guard let player = playerVC?.player else { return }
        // 必须在换源前记下播放意图：新 AVPlayer 默认就是 .paused，换源后再读 isUserPaused 会误判成用户暂停
        let shouldResume = !isUserPaused
        guard shouldResume else {
            Logger.info("[cdn] 用户已暂停，取消 host 切换")
            return
        }
        let currentTime = player.currentTime().seconds
        guard currentTime > 0 else { return }
        currentPlaybackTime = currentTime

        // 关掉 readyToPlay 自动 play，改由下面按 shouldResume 显式 play；异步恢复默认，避开尚未送达的 status KVO
        let commonVC = playerVC?.parent as? CommonPlayerViewController
        commonVC?.autoPlayWhenReady = false
        defer {
            // 延后到下一个 main actor 周期再恢复默认值，避开 playmedia 期间尚未送达的 status KVO
            Task { @MainActor [weak commonVC] in
                commonVC?.autoPlayWhenReady = true
            }
        }

        do {
            let generation = beginLoadGeneration()
            try await playmedia(urlInfo: playData.videoPlayURLInfo,
                                playerInfo: playData.playerInfo,
                                generation: generation,
                                maxQuality: lastMaxQuality,
                                streamIndex: lastStreamIndex,
                                preferredHost: host,
                                isQualitySwitch: true)
            if let newPlayer = playerVC?.player {
                await newPlayer.seek(to: CMTime(seconds: currentPlaybackTime, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
                if shouldResume {
                    newPlayer.play()
                } else {
                    newPlayer.pause()
                }
            }
        } catch {
            Logger.warn("[cdn] 切换 host 失败: \(error)")
        }
    }

    func playerDidDismiss(playerVC: AVPlayerViewController) {
        guard reportWatchHistory else { return }
        guard let currentTime = playerVC.player?.currentTime().seconds, currentTime > 0 else { return }
        WebRequest.reportWatchHistory(aid: playData.aid, cid: playData.cid, currentTime: Int(currentTime), epid: playData.epid, seasonId: playData.seasonId, subType: playData.subType)
    }

    /// 与资源加载器选主视频流的逻辑对齐（共用 BVideoStreamSelection），取出该流各 CDN host 的代表 URL，供起播轻量测速。
    private func primaryCDNCandidates(from info: VideoPlayURLInfo, maxQuality: Int?, streamIndex: Int?) -> [String] {
        let videos = BVideoStreamSelection.select(videos: info.dash.video,
                                                  streamIndex: streamIndex,
                                                  maxQuality: maxQuality)
        guard let primary = videos.max(by: { $0.bandwidth < $1.bandwidth }) else { return [] }
        var seenHosts = Set<String>()
        return primary.playableURLs.filter { url in
            guard let host = URLComponents(string: url)?.host else { return false }
            return seenHosts.insert(host).inserted
        }
    }

    func playerWillCleanUp(playerVC: AVPlayerViewController) {
        invalidatePendingLoad(tearingDown: true)
    }

    private func startLoad(urlInfo: VideoPlayURLInfo,
                           playerInfo: PlayerInfo?,
                           maxQuality: Int? = nil,
                           streamIndex: Int? = nil,
                           isQualitySwitch: Bool = false)
    {
        let generation = beginLoadGeneration()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.playmedia(urlInfo: urlInfo,
                                         playerInfo: playerInfo,
                                         generation: generation,
                                         maxQuality: maxQuality,
                                         streamIndex: streamIndex,
                                         isQualitySwitch: isQualitySwitch)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.loadGeneration == generation,
                      self.playerVC != nil
                else { return }
                Logger.warn("[player] Failed to prepare media: \(error)")
                // 装载失败也可能是编码流本身有问题，先试同画质换编码，候选耗尽再报错。
                // 必须另起 Task：attemptCodecFailover 里 beginLoadGeneration 会 cancel loadTask，
                // 而这里正在 loadTask 自己的闭包里执行，await 会让切换还没开始就被取消
                Task { @MainActor [weak self] in
                    await self?.attemptCodecFailover(reason: "媒体装载失败", fallbackMessage: error.localizedDescription)
                }
            }
        }
    }

    private func beginLoadGeneration() -> Int {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        return loadGeneration
    }

    private func invalidatePendingLoad(tearingDown: Bool) {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        disarmStartupWatchdog()
        playerDelegate = nil
        if tearingDown {
            playerVC = nil
        }
    }

    private func ensureActiveLoad(_ generation: Int) throws -> AVPlayerViewController {
        guard !Task.isCancelled,
              loadGeneration == generation,
              let playerVC
        else {
            throw CancellationError()
        }
        return playerVC
    }

    @MainActor
    private func playmedia(urlInfo: VideoPlayURLInfo,
                           playerInfo: PlayerInfo?,
                           generation: Int,
                           maxQuality: Int? = nil,
                           streamIndex: Int? = nil,
                           preferredHost: String? = nil,
                           isQualitySwitch: Bool = false) async throws
    {
        _ = try ensureActiveLoad(generation)
        let prepared = try await preparedMedia(urlInfo: urlInfo,
                                               playerInfo: playerInfo,
                                               maxQuality: maxQuality,
                                               streamIndex: streamIndex,
                                               preferredHost: preferredHost,
                                               isQualitySwitch: isQualitySwitch)
        // The await above may finish after a newer load generation. Validate
        // before retaining its resource-loader delegate or touching the player.
        let playerVC = try ensureActiveLoad(generation)
        let delegate = prepared.delegate
        let asset = prepared.asset
        playerDelegate = delegate

        // AVKit 不允许在同一场全屏播放里反复切换该属性，因此只在首次装配资源时计算一次。
        if !isQualitySwitch {
            playerVC.appliesPreferredDisplayCriteriaAutomatically = shouldApplyContentMatch(delegate: delegate)
        }

        await prepare(toPlay: asset, generation: generation)
    }

    private func preparedMedia(urlInfo: VideoPlayURLInfo,
                               playerInfo: PlayerInfo?,
                               maxQuality: Int?,
                               streamIndex: Int?,
                               preferredHost: String?,
                               isQualitySwitch: Bool) async throws -> PreparedPlayerMedia
    {
        if !isQualitySwitch,
           maxQuality == nil,
           streamIndex == nil,
           preferredHost == nil,
           let mediaWarmupManager
        {
            return try await mediaWarmupManager.preparedMedia(for: playInfo)
        }
        lastStalls = 0
        lastDroppedFrames = 0
        lastMaxQuality = maxQuality
        lastStreamIndex = streamIndex

        var resolvedHost = preferredHost
        if resolvedHost == nil {
            let candidates = primaryCDNCandidates(from: urlInfo, maxQuality: maxQuality, streamIndex: streamIndex)
            if let best = await CDNDiagnostics.pickFastestHost(urls: candidates) {
                resolvedHost = best
                Logger.info("[cdn] 起播选用 host: \(best)")
            }
        }

        return try await PlayerMediaFactory.prepare(aid: playData.aid,
                                                    urlInfo: urlInfo,
                                                    playerInfo: playerInfo,
                                                    maxQuality: maxQuality,
                                                    streamIndex: streamIndex,
                                                    preferredHost: resolvedHost)
    }

    @MainActor
    func switchQuality(to qualityId: Int, streamIndex: Int?) async {
        guard let player = playerVC?.player else { return }

        let currentTime = player.currentTime().seconds
        guard currentTime > 0 else { return }

        // 保存当前播放位置
        currentPlaybackTime = currentTime

        // 重新加载视频，使用新的画质
        do {
            let generation = beginLoadGeneration()
            try await playmedia(urlInfo: playData.videoPlayURLInfo,
                                playerInfo: playData.playerInfo,
                                generation: generation,
                                maxQuality: qualityId,
                                streamIndex: streamIndex,
                                isQualitySwitch: true)

            // 恢复播放位置并继续播放
            guard loadGeneration == generation,
                  !Task.isCancelled,
                  playerVC != nil,
                  let newPlayer = playerVC?.player
            else { return }
            await newPlayer.seek(to: CMTime(seconds: currentPlaybackTime, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
            guard loadGeneration == generation, !Task.isCancelled else { return }
            newPlayer.play()
        } catch is CancellationError {
            return
        } catch {
            Logger.warn("[quality] Failed to switch quality: \(error)")
        }
    }

    private func shouldApplyContentMatch(delegate: BilibiliVideoResourceLoaderDelegate) -> Bool {
        guard Settings.contentMatch else { return false }
        guard Settings.contentMatchOnlyInHDR else { return true }
        return delegate.isHDR == true
    }

    @MainActor
    func prepare(toPlay asset: AVURLAsset, generation: Int) async {
        guard loadGeneration == generation,
              !Task.isCancelled,
              let playerVC
        else { return }
        let playerItem = AVPlayerItem(asset: asset)

        // 设置 preferredPeakBitRate 为一个很高的值，让 AVPlayer 优先选择高码率流
        // 0 表示无限制，让 AVPlayer 根据网络条件自动选择最高可用码率
        playerItem.preferredPeakBitRate = 0

        // 之前设成 60s 是为了扛 CDN 吞吐抖动，但 BANDWIDTH 声明错误的根因已修复，
        // 实测 CDN 吞吐充裕，不再需要这么激进的预缓冲。60s 在连续快进时的副作用是：
        // 每次 seek 都会立刻为新位置起一大批 60s 的 range 请求，下一个 seek 一来又整体取消重来，
        // 密集 seek 下网络连接层疲于开连接/取消，表现为长时间无响应。降到 15s 大幅减少这种抖动。
        playerItem.preferredForwardBufferDuration = 15

        let player = AVPlayer(playerItem: playerItem)
        // 关掉 AVFoundation 的自动媒体选择 —— 字幕轨完全由 SubtitlePlugin 管理
        // （它会显式选中偏好语言，或显式关闭）。开着的话系统会按 tvOS 的字幕语言偏好
        // 自己挑一条：实测【人民的名义】这类"只有 AI 英/日文翻译轨"的稿件，会在快进/快退
        // 触发的重新装载时被自动选中英文轨，画面闪出一句英文字幕再消失。
        // 音频侧不受影响：manifest 已把首选音轨标成 DEFAULT=YES，按 HLS 规则会使用它。
        // 注意 tvOS 的 AVPlayerItem 没有这个属性，只有 AVPlayer 有。
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.automaticallyWaitsToMinimizeStalling = minimizeStalling
        player.isMuted = isMuted
        guard loadGeneration == generation, !Task.isCancelled else {
            player.pause()
            player.replaceCurrentItem(with: nil)
            return
        }
        playerVC.player = nil
        guard loadGeneration == generation, !Task.isCancelled else {
            player.pause()
            player.replaceCurrentItem(with: nil)
            return
        }
        playerVC.player = player
        armStartupWatchdog()
    }

    // MARK: - 编码格式故障自动切换

    private func armStartupWatchdog() {
        disarmStartupWatchdog()
        startupWatchdog = Timer.scheduledTimer(withTimeInterval: startupTimeoutSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startupWatchdogFired()
            }
        }
    }

    private func disarmStartupWatchdog() {
        startupWatchdog?.invalidate()
        startupWatchdog = nil
    }

    @MainActor
    private func startupWatchdogFired() {
        startupWatchdog = nil
        guard let player = playerVC?.player, player.currentItem != nil else { return }
        // 用户主动暂停期间不计超时，顺延一个观察期
        if isUserPaused {
            armStartupWatchdog()
            return
        }
        // 已经在播了就无事发生；还在转圈/卡死/报错则换编码自救
        guard player.timeControlStatus != .playing, player.rate <= 0 else { return }
        Logger.info("[failover] 起播 \(Int(startupTimeoutSeconds))s 未开始(tcs=\(player.timeControlStatus.rawValue))，尝试切换编码")
        Task {
            await self.attemptCodecFailover(reason: "起播超时")
        }
    }

    /// 当前实际生效的视频流：与资源加载器同一套选择规则（含默认档位锁定），按 lastMaxQuality/lastStreamIndex 复算
    private func effectiveStream() -> VideoPlayURLInfo.DashInfo.DashMediaInfo? {
        BVideoStreamSelection.select(videos: playData.videoPlayURLInfo.dash.video,
                                     streamIndex: lastStreamIndex,
                                     maxQuality: lastMaxQuality).first
    }

    /// 同一画质档位下换一个编码：优先 AVC（解码兼容性最好），已试败过的跳过
    private func codecFailoverStreamIndex(after current: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> Int? {
        let videos = playData.videoPlayURLInfo.dash.video
        let candidates = videos.indices.filter { index in
            videos[index].id == current.id
                && videos[index].codecs != current.codecs
                && !failedStreamKeys.contains("\(current.id):\(videos[index].codecs)")
        }
        return candidates.min { lhs, rhs in
            let lhsAvc = !videos[lhs].isHevc
            let rhsAvc = !videos[rhs].isHevc
            if lhsAvc != rhsAvc { return lhsAvc }
            return lhs < rhs
        }
    }

    /// 解码出错/起播超时/装载失败时的自救：同画质档位换一个编码重载，尽量保住当前进度；
    /// 候选耗尽或用户已手动锁定具体流时不再折腾，交回原有失败呈现
    @MainActor
    private func attemptCodecFailover(reason: String, fallbackMessage: String? = nil) async {
        guard !isCodecFailingOver else { return }
        if let last = lastCodecSwitchAt, Date().timeIntervalSince(last) < codecSwitchCooldown {
            Logger.info("[failover] \(reason)：冷静期内，跳过")
            return
        }
        guard let current = effectiveStream() else {
            if let fallbackMessage { onLoadFailure?(fallbackMessage) }
            return
        }
        let currentKey = "\(current.id):\(current.codecs)"
        failedStreamKeys.insert(currentKey)
        guard let targetIndex = codecFailoverStreamIndex(after: current) else {
            Logger.info("[failover] \(reason)：画质 \(current.id) 无其他编码可切换")
            if let fallbackMessage { onLoadFailure?(fallbackMessage) }
            return
        }
        isCodecFailingOver = true
        defer { isCodecFailingOver = false }
        lastCodecSwitchAt = Date()
        stallUnhealthyStreak = 0
        let target = playData.videoPlayURLInfo.dash.video[targetIndex]
        Logger.info("[failover] \(reason)：切换编码 \(current.codecs) -> \(target.codecs) (画质 \(current.id))")

        let player = playerVC?.player
        // 换源会重建 AVPlayer：先记下播放意图与进度，装完按原状态恢复
        let shouldResume = player == nil ? true : !isUserPaused
        let currentTime = player?.currentTime().seconds ?? 0

        // 关掉 readyToPlay 自动 play，改由下面按 shouldResume 显式恢复（与 switchHost 同一套规避）
        let commonVC = playerVC?.parent as? CommonPlayerViewController
        commonVC?.autoPlayWhenReady = false
        defer {
            Task { @MainActor [weak commonVC] in
                commonVC?.autoPlayWhenReady = true
            }
        }

        do {
            let generation = beginLoadGeneration()
            try await playmedia(urlInfo: playData.videoPlayURLInfo,
                                playerInfo: playData.playerInfo,
                                generation: generation,
                                maxQuality: nil,
                                streamIndex: targetIndex,
                                isQualitySwitch: true)
            guard loadGeneration == generation, !Task.isCancelled, playerVC != nil else { return }
            if currentTime > 0, let newPlayer = playerVC?.player {
                await newPlayer.seek(to: CMTime(seconds: currentTime, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
                guard loadGeneration == generation, !Task.isCancelled else { return }
            }
            if shouldResume {
                playerVC?.player?.play()
            } else {
                playerVC?.player?.pause()
            }
        } catch is CancellationError {
            return
        } catch {
            // 新编码连装载都过不去：记入试败名单，交回失败呈现
            failedStreamKeys.insert("\(current.id):\(target.codecs)")
            Logger.warn("[failover] 切换编码失败: \(error)")
            onLoadFailure?(error.localizedDescription)
        }
    }
}
