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
    /// 观看进度心跳与最终上报：连播/换集/后台退出都不再依赖“播放器关闭”这一个时机。
    private var historyTimer: Timer?
    private var lastHistoryReportAt: Date?
    private var lastHistoryReportedSeconds: Double = -1
    private var lastStalls = 0
    private var lastDroppedFrames = 0
    private var cdnProbeReport = ""
    private var isProbingCDN = false
    /// 当前会话实际传输模式（创建播放资源时快照；设置只影响新建会话）。
    private var transportMode: MediaTransportMode = .direct
    /// 加速不可恢复时的播放器级直连恢复次数（有界，避免无限重试）。
    private var acceleratedRecoveryAttempts = 0
    private let maxAcceleratedRecoveries = 1
    /// 播放器重建串行闸：切画质/换 host/编码自救/加速回退都走同一条重建链，
    /// 并发进入会互相踩 autoPlayWhenReady 与 generation，导致错位起播。
    private var isRebuildingPlayer = false
    /// 单调时钟记录的连续等待起点（systemUptime 秒）。nil 表示当前不在等待。
    /// 日志周期 5s 且需两次不健康采样才计数一次，周期计数实际对应约 120s；
    /// 以单调时长为准，60s 到即回退，不依赖双层计数。
    private var acceleratedWaitingSince: TimeInterval?

    /// 加速等待看门狗：isWaiting 为真且非用户暂停时累计单调时长，
    /// 满 60s 触发一次有界直连恢复；任何进展（或用户暂停）即清零。
    /// 由 checkStallHealth 与无 access log 的起播阶段共同驱动。
    private func noteAcceleratedWaiting(isWaiting: Bool) {
        guard transportMode == .accelerated else {
            acceleratedWaitingSince = nil
            return
        }
        guard isWaiting, !isUserPaused else {
            acceleratedWaitingSince = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let since = acceleratedWaitingSince {
            if now - since >= 60 {
                acceleratedWaitingSince = nil
                Logger.info("[cdn] 加速模式持续等待超 60s，尝试直连恢复")
                Task { @MainActor [weak self] in
                    await self?.recoverAcceleratedToDirect()
                }
            }
        } else {
            acceleratedWaitingSince = now
        }
    }

    // 运行时 CDN 健康检测：只在真实卡顿时换 host，不用 observed/indicated 比特率比
    // （indicated 常是峰值 BANDWIDTH，播放流畅时 observed 低于它完全正常）
    private var stallUnhealthyStreak = 0
    private var isEvaluatingHostSwitch = false
    private var lastHostSwitchAt: Date?
    /// 连续几次处于卡顿/等待缓冲才触发，避免单次抖动
    private let stallTriggerCount = 2
    /// 换完 host 后的冷静期。换源会重建 AVPlayer 并 seek，把已缓冲的内容全部丢弃 ——
    /// 换得太勤本身就会制造出「每隔一会儿卡一下」，故把冷静期从 30s 拉长到 120s。
    private let hostSwitchCooldown: TimeInterval = 120
    /// 只有备选实测比当前节点快这么多倍才值得换源，避免在测速噪声上反复横跳
    private let switchSpeedMargin: Double = 1.5
    private let networkLogInterval: TimeInterval = 5
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    /// 起播断点只应用一次。换画质/换 host/换编码各路径已按当前进度 seek，
    /// 若 readyToPlay 时再按 playerStartPos seek 一次，两次远距离 seek 会互相取消 ——
    /// 真机表现为「切格式后进度条倒退」，以及 AVPlayer 卡在 waitingToPlay 不再起播。
    private var hasAppliedStartPosition = false
    /// 播放器 timeControlStatus 观察：seek/缓冲卡死最可靠的入口
    private var timeControlObservation: NSKeyValueObservation?
    /// 本次装配是否真正出过画面。首次起播的等待交给 startupWatchdog，
    /// 自救看门狗只处理"播过之后再 seek 卡住"的场景，避免打扰正常慢起播。
    private var hasStartedPlayback = false

    // ===== 编码格式故障自动切换 =====
    /// 起播看门狗：媒体装配完成后这么久仍未起播（出错/卡死/永远 buffering）视为超时
    private let startupTimeoutSeconds: TimeInterval = 20
    private var startupWatchdog: Timer?
    /// seek/换源卡在 waitingToPlay 时的短自救看门狗。
    /// 起播看门狗在 playerDidStart 就撤销了，播放中途快进/快退卡住时没有任何计时器在跑。
    private let stallRecoveryDelay: TimeInterval = 8
    private var stallRecoveryWatchdog: Timer?
    private var stallRecoveryAttempts = 0
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
        historyTimer?.invalidate()
        startupWatchdog?.invalidate()
        stallRecoveryWatchdog?.invalidate()
        timeControlObservation?.invalidate()
    }

    /// 供 DebugPlugin 浮层显示的网络诊断信息
    var networkDebugInfo: String {
        var lines = [String]()
        if let mode = playerDelegate?.effectiveTransportMode, mode != .direct {
            lines.append("transport: \(mode == .accelerated ? "accel" : "proxy")")
        }
        if let host = playerDelegate?.currentSegmentHost {
            lines.append("segment host: \(host)")
        }
        if let accel = playerDelegate?.accelerationDebugInfo, !accel.isEmpty {
            lines.append(accel)
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

    func playerDidChange(player: AVPlayer) {
        // AVPlayerItemPlaybackStalled 不保证在"seek 到未缓冲区域后一直 waiting"时发出，
        // 而起播看门狗在 playerDidStart 就撤销了，所以只能直接盯 timeControlStatus。
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.playerTimeControlStatusDidChange(player)
            }
        }
    }

    func playerWillStart(player: AVPlayer) {
        // 只有本次播放的第一次装配才回到详情页断点；后续换 item 由各路径自己恢复进度
        guard !hasAppliedStartPosition else { return }
        hasAppliedStartPosition = true
        guard let playerStartPos = playData.playerStartPos, playerStartPos > 0 else { return }
        player.seek(to: CMTime(seconds: Double(playerStartPos), preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func playerItemDidChange(playerItem _: AVPlayerItem) {
        // 监控在"装载完成"就启动，而不是等 playerDidStart：快进/快退卡住时播放根本没开始过，
        // 旧实现下没有任何计时器在跑，卡死只能靠用户退出。
        startNetworkLogging()
    }

    func playerDidStall(player: AVPlayer) {
        guard player === playerVC?.player, !isUserPaused else { return }
        armStallRecoveryWatchdog()
    }

    func playerDidStart(player: AVPlayer) {
        startNetworkLogging()
        startHistoryReporting()
        // rate 变正不代表已经出画面：seek/缓冲等待时 rate 也可能是 1。
        // 真正的起播以 timeControlStatus == .playing 为准（见 playerTimeControlStatusDidChange）。
        guard player.timeControlStatus == .playing else { return }
        disarmStartupWatchdog()
        disarmStallRecoveryWatchdog()
        stallRecoveryAttempts = 0
    }

    func playerDidCleanUp(player: AVPlayer) {
        // 换集/换画质会先走 removeAllPlugins：此时 player 还在，先记下这一集的最终进度。
        reportHistory(force: true)
        stopHistoryReporting()
        disarmStartupWatchdog()
        disarmStallRecoveryWatchdog()
        stallRecoveryAttempts = 0
        timeControlObservation = nil
        stopNetworkLogging()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// AVPlayerItem 进入 .failed：优先同画质换编码自救，候选耗尽再走原有失败呈现
    func playerDidFail(player: AVPlayer) {
        disarmStartupWatchdog()
        // 被换掉的旧 item 报错不作数
        guard player === playerVC?.player, player.currentItem?.status == .failed else { return }
        // 加速传输整体失败时有限恢复为直连；用户暂停时不擅自续播。
        if transportMode == .accelerated {
            Task { @MainActor [weak self] in
                await self?.recoverAcceleratedToDirect()
            }
            return
        }
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

    // MARK: - 观看进度上报

    /// 30 秒心跳 + 换集/关闭时的最终上报。
    /// 旧实现只在 `playerDidDismiss` 上报；自动连播/换画质/后台杀进程都会丢进度。
    private func startHistoryReporting() {
        guard reportWatchHistory, historyTimer == nil else { return }
        historyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.reportHistory(force: false)
        }
    }

    private func stopHistoryReporting() {
        historyTimer?.invalidate()
        historyTimer = nil
    }

    private func reportHistory(force: Bool) {
        guard reportWatchHistory else { return }
        let playerTime = playerVC?.player?.currentTime().seconds
        let seconds: Double
        if let playerTime, playerTime.isFinite, playerTime > 0 {
            seconds = playerTime
        } else {
            seconds = currentPlaybackTime
        }
        guard seconds > 0 else { return }

        let now = Date()
        if force {
            // 关闭播放器会连续触发 dismiss + cleanup，同秒内只发一次最终进度。
            if lastHistoryReportedSeconds >= 0,
               abs(seconds - lastHistoryReportedSeconds) < 1,
               let last = lastHistoryReportAt,
               now.timeIntervalSince(last) < 5
            {
                return
            }
        } else if let last = lastHistoryReportAt, now.timeIntervalSince(last) < 25 {
            return
        } else if lastHistoryReportedSeconds >= 0, abs(seconds - lastHistoryReportedSeconds) < 1 {
            // 暂停/缓冲时位置没变，不必每 30s 打一次同样的 heartbeat。
            return
        }

        lastHistoryReportAt = now
        lastHistoryReportedSeconds = seconds
        WebRequest.reportWatchHistory(aid: playData.aid,
                                      cid: playData.cid,
                                      currentTime: Int(seconds),
                                      epid: playData.epid,
                                      seasonId: playData.seasonId,
                                      subType: playData.subType)
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
        else {
            // 起播尚无 access log 时 checkStallHealth 不会执行，这里的等待看门狗
            // 同样需要覆盖，否则首帧卡死时 60s 回退永远不触发。
            noteAcceleratedWaiting(isWaiting: playerVC?.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            return
        }
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
        // 每个采样周期都刷新加速等待计时：健康/早退分支也必须清零，
        // 否则旧的等待起点会跨过一段健康播放，导致下一次短卡顿被误判为“已等 60s”。
        if transportMode == .accelerated {
            noteAcceleratedWaiting(isWaiting: isWaitingToPlay && !isUserPaused)
        }
        guard !isUserPaused, !isEvaluatingHostSwitch else {
            stallUnhealthyStreak = 0
            return
        }
        if let lastSwitch = lastHostSwitchAt, Date().timeIntervalSince(lastSwitch) < hostSwitchCooldown {
            return
        }
        // 等待态的本地自救由 stallRecoveryWatchdog 接管，避免换 CDN 与重 seek 两条恢复链路
        // 同时重建播放器（autoPlayWhenReady 等共享状态会互相踩）
        if stallRecoveryWatchdog != nil {
            stallUnhealthyStreak = 0
            return
        }
        // 起播阶段的等待由 startupWatchdog（20s → 换编码）负责，这里只处理"播过之后"的卡顿，
        // 否则正常起播慢几秒就会被误判成 CDN 有问题而白换一次源
        guard hasStartedPlayback else {
            stallUnhealthyStreak = 0
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

        // 加速模式已在下载器内做 CDN 调度、竞速和隔离，不再重复起播测速/换 host；
        // 只有整体不可恢复时才走有限的播放器级直连恢复，避免两层同时竞争控制权。
        // 因此普通 waiting/stall 一律交由下载器：长时无进展由单调时钟看门狗兜底。
        if transportMode == .accelerated {
            return
        }

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
        if let currentMbps {
            // 只有备选「明显更快」才切。旧实现里 target >= current*0.7 就走「强制尝试」，
            // 在带噪声的测速下几乎必然成立 —— 于是每次卡顿都换一个 host，而每次换源都要
            // 重建 AVPlayer + seek、丢掉已缓冲的几秒，反而制造出周期性卡顿。
            guard targetMbps >= currentMbps * switchSpeedMargin else {
                Logger.info("[cdn] 备选 \(target.host) (\(String(format: "%.1f", targetMbps))Mbps) 未明显快于当前 \(currentHost) (\(String(format: "%.1f", currentMbps))Mbps)，保持")
                return
            }
            reason = "测速明显更快 (\(String(format: "%.1f", currentMbps))→\(String(format: "%.1f", targetMbps))Mbps)"
        } else {
            // 当前节点自身测速失败：无法比较，只能按「当前不可用」处理
            reason = "当前节点测速失败"
        }

        lastHostSwitchAt = Date()
        Logger.info("[cdn] 切换 host: \(currentHost) -> \(target.host) (实测\(String(format: "%.1f", targetMbps))Mbps, \(reason))")
        await switchHost(to: target.host)
    }

    @MainActor
    private func switchHost(to host: String) async {
        guard !isRebuildingPlayer else {
            Logger.info("[cdn] 已有播放器重建在进行，跳过换 host")
            return
        }
        isRebuildingPlayer = true
        defer { isRebuildingPlayer = false }
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
        // 换源路径下面会按 currentPlaybackTime 恢复，禁止 readyToPlay 再回断点
        hasAppliedStartPosition = true

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
        reportHistory(force: true)
        stopHistoryReporting()
    }

    /// 与资源加载器选主视频流的逻辑对齐（共用 BVideoStreamSelection），取出该流各 CDN host 的代表 URL，供起播轻量测速。
    private func primaryCDNCandidates(from info: VideoPlayURLInfo, maxQuality: Int?, streamIndex: Int?) -> [String] {
        let videos = BVideoStreamSelection.select(videos: info.dash.video,
                                                  streamIndex: streamIndex,
                                                  maxQuality: maxQuality)
        guard let primary = videos.max(by: { $0.bandwidth < $1.bandwidth }) else { return [] }
        var seenHosts = Set<String>()
        return primary.playableURLs.filter { url in
            guard let host = url.urlHost else { return false }
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
        acceleratedRecoveryAttempts = 0
        acceleratedWaitingSince = nil
        transportMode = Settings.multiCDNEnabled ? .accelerated : .direct
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
                           isQualitySwitch: Bool = false,
                           forceTransport: MediaTransportMode? = nil) async throws
    {
        _ = try ensureActiveLoad(generation)
        let prepared = try await preparedMedia(urlInfo: urlInfo,
                                               playerInfo: playerInfo,
                                               maxQuality: maxQuality,
                                               streamIndex: streamIndex,
                                               preferredHost: preferredHost,
                                               isQualitySwitch: isQualitySwitch,
                                               forceTransport: forceTransport)
        // The await above may finish after a newer load generation. Validate
        // before retaining its resource-loader delegate or touching the player.
        let playerVC = try ensureActiveLoad(generation)
        let delegate = prepared.delegate
        let asset = prepared.asset
        playerDelegate = delegate
        // 以实际传输模式为准：代理启动失败时播放列表已回退直连 URI，
        // 此时不得按加速处理（否则卡顿会被误送入加速恢复流程）。
        transportMode = delegate.effectiveTransportMode

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
                               isQualitySwitch: Bool,
                               forceTransport: MediaTransportMode? = nil) async throws -> PreparedPlayerMedia
    {
        // 传输模式快照：设置只影响新建播放资源，已开始的不重建
        let mode = forceTransport ?? (Settings.multiCDNEnabled ? .accelerated : .direct)
        if !isQualitySwitch,
           maxQuality == nil,
           streamIndex == nil,
           preferredHost == nil,
           forceTransport == nil,
           let mediaWarmupManager
        {
            let prepared = try await mediaWarmupManager.preparedMedia(for: playInfo)
            transportMode = prepared.delegate.effectiveTransportMode
            return prepared
        }
        lastStalls = 0
        lastDroppedFrames = 0
        lastMaxQuality = maxQuality
        lastStreamIndex = streamIndex

        var resolvedHost = preferredHost
        // 加速模式使用下载器内的 CDN 动态调度，不再重复执行旧版起播测速
        if resolvedHost == nil, mode != .accelerated {
            let candidates = primaryCDNCandidates(from: urlInfo, maxQuality: maxQuality, streamIndex: streamIndex)
            if let best = await CDNDiagnostics.pickFastestHost(urls: candidates) {
                resolvedHost = best
                Logger.info("[cdn] 起播选用 host: \(best)")
            }
        } else if mode == .accelerated {
            Logger.info("[cdn] 加速模式：跳过起播测速，由下载器动态调度")
        }

        return try await PlayerMediaFactory.prepare(aid: playData.aid,
                                                    urlInfo: urlInfo,
                                                    playerInfo: playerInfo,
                                                    maxQuality: maxQuality,
                                                    streamIndex: streamIndex,
                                                    preferredHost: resolvedHost,
                                                    transportMode: mode)
    }

    /// 加速传输不可恢复时的有限直连恢复：记录播放时间与用户暂停意图，
    /// 取消旧会话、创建新的直连资源、恢复位置。复用 generation 与播放意图保护。
    @MainActor
    private func recoverAcceleratedToDirect() async {
        guard acceleratedRecoveryAttempts < maxAcceleratedRecoveries else {
            Logger.info("[cdn] 加速恢复次数已达上限，不再自动恢复")
            return
        }
        guard !isRebuildingPlayer else {
            Logger.info("[cdn] 已有播放器重建在进行，跳过加速回退")
            return
        }
        isRebuildingPlayer = true
        defer { isRebuildingPlayer = false }
        guard let player = playerVC?.player else { return }
        // 必须在重建前记下播放意图：新 AVPlayer 默认 .paused，之后再读会误判
        let shouldResume = !isUserPaused
        guard shouldResume else {
            Logger.info("[cdn] 用户已暂停，取消加速直连恢复")
            return
        }
        // 起播失败时 currentTime 为 0：用已知的起始位置恢复，不直接放弃回退
        let currentTime = player.currentTime().seconds
        if currentTime > 0 {
            currentPlaybackTime = currentTime
        } else if let startPos = playData.playerStartPos, startPos > 0 {
            currentPlaybackTime = Double(startPos)
        } else {
            currentPlaybackTime = 0
        }
        acceleratedRecoveryAttempts += 1
        Logger.info("[cdn] 加速传输不可恢复，第 \(acceleratedRecoveryAttempts) 次回退直连")

        let commonVC = playerVC?.parent as? CommonPlayerViewController
        commonVC?.autoPlayWhenReady = false
        defer {
            DispatchQueue.main.async {
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
                                isQualitySwitch: true,
                                forceTransport: .direct)
            if let newPlayer = playerVC?.player {
                // 起播失败恢复时位置为 0，无需 seek，直接按原意图播放
                if currentPlaybackTime > 0 {
                    await newPlayer.seek(to: CMTime(seconds: currentPlaybackTime, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if shouldResume {
                    newPlayer.play()
                } else {
                    newPlayer.pause()
                }
            }
        } catch {
            Logger.warn("[cdn] 加速回退直连失败: \(error)")
        }
    }

    @MainActor
    func switchQuality(to qualityId: Int, streamIndex: Int?) async -> Bool {
        guard !isRebuildingPlayer else {
            Logger.info("[quality] 已有播放器重建在进行，跳过本次画质切换")
            return false
        }
        isRebuildingPlayer = true
        defer { isRebuildingPlayer = false }
        guard let player = playerVC?.player else { return false }

        let currentTime = player.currentTime().seconds
        guard currentTime.isFinite else { return false }
        // 用户按暂停时切画质，不应被强行续播；0 秒也应允许切（旧实现会静默 return）
        let shouldResume = !isUserPaused

        // 保存当前播放位置
        currentPlaybackTime = max(0, currentTime)
        // 这条路径装完后会按当前进度 seek，不能再让 readyToPlay 回到详情页断点
        hasAppliedStartPosition = true

        // 与 switchHost 一致：关掉 readyToPlay 自动起播，等 seek 到当前进度再显式 play，
        // 否则新 item 会先从片头/断点起播，随即被 seek 打断，再次制造取流抖动
        let commonVC = playerVC?.parent as? CommonPlayerViewController
        commonVC?.autoPlayWhenReady = false
        defer {
            Task { @MainActor [weak commonVC] in
                commonVC?.autoPlayWhenReady = true
            }
        }

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
            else { return false }
            await newPlayer.seek(to: CMTime(seconds: currentPlaybackTime, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
            guard loadGeneration == generation, !Task.isCancelled else { return false }
            if shouldResume {
                newPlayer.play()
            } else {
                newPlayer.pause()
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            Logger.warn("[quality] Failed to switch quality: \(error)")
            return false
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

    // MARK: - seek 卡死自救

    private func playerTimeControlStatusDidChange(_ player: AVPlayer) {
        // 只处理当前播放器；换源瞬间旧 player 的 KVO 可能晚到
        guard player === playerVC?.player else { return }
        switch player.timeControlStatus {
        case .playing:
            hasStartedPlayback = true
            disarmStartupWatchdog()
            disarmStallRecoveryWatchdog()
            stallRecoveryAttempts = 0
        case .waitingToPlayAtSpecifiedRate:
            // 媒体未 ready 的等待属于正常起播过程，交给 startupWatchdog；
            // ready 之后还长期 waiting，且此前已经出过画面，才是 seek/取流被卡住
            guard hasStartedPlayback, player.currentItem?.status == .readyToPlay else { return }
            armStallRecoveryWatchdog()
        case .paused:
            // 用户暂停/播放结束：停止自救，避免自动 play 顶掉用户的暂停
            disarmStallRecoveryWatchdog()
            stallRecoveryAttempts = 0
        @unknown default:
            break
        }
    }

    private func armStallRecoveryWatchdog() {
        disarmStallRecoveryWatchdog()
        stallRecoveryWatchdog = Timer.scheduledTimer(withTimeInterval: stallRecoveryDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stallRecoveryFired()
            }
        }
    }

    private func disarmStallRecoveryWatchdog() {
        stallRecoveryWatchdog?.invalidate()
        stallRecoveryWatchdog = nil
    }

    @MainActor
    private func stallRecoveryFired() {
        stallRecoveryWatchdog = nil
        guard let player = playerVC?.player, let item = player.currentItem else { return }
        // 已经在播或用户主动暂停就什么都不做；只有播过之后、ready 状态下的 waiting 才视为卡死
        guard hasStartedPlayback,
              !isUserPaused,
              player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              item.status == .readyToPlay
        else {
            stallRecoveryAttempts = 0
            return
        }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }

        stallRecoveryAttempts += 1
        guard stallRecoveryAttempts <= 2 else {
            // 同一位置连按两次都起不来，交给换编码的原有自救链路
            stallRecoveryAttempts = 0
            Logger.info("[stall] 重试当前位置无效，交给换编码")
            Task { await self.attemptCodecFailover(reason: "播放卡死") }
            return
        }

        // 带 1s 容差重 seek：零容差的精确 seek 在密集快进/快退下最容易把 AVPlayer 挂在
        // waitingToPlay 上，给一点容差能让它直接落到可解的帧上
        Logger.info("[stall] 卡在 waitingToPlay \(Int(stallRecoveryDelay))s，重试当前位置 \(String(format: "%.1f", seconds))s（第 \(stallRecoveryAttempts) 次）")
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: tolerance,
                    toleranceAfter: tolerance)
        // 不依赖 seek 回调（真卡死时回调也可能不来）：先续上计时器，
        // 真正恢复播放后 .playing 会把计时器撤掉
        armStallRecoveryWatchdog()
        player.play()
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
        // 已经在播了就无事发生；还在转圈/卡死/报错则换编码自救。
        // 不能用 rate 判断：缓冲/seek 等待时 rate 也可能是 1
        guard player.timeControlStatus != .playing else { return }
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
        guard !isRebuildingPlayer else {
            Logger.info("[failover] 已有播放器重建在进行，跳过编码自救")
            return
        }
        isRebuildingPlayer = true
        defer { isRebuildingPlayer = false }
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
        // 还没起播就失败时 currentTime 是 0，此时应回到详情页断点而不是片头
        let resumeTime = currentTime > 1 ? currentTime : Double(playData.playerStartPos ?? 0)
        // 换编码重装后按 resumeTime 自行恢复，禁止 readyToPlay 再回断点
        hasAppliedStartPosition = true

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
            if resumeTime > 0, let newPlayer = playerVC?.player {
                await newPlayer.seek(to: CMTime(seconds: resumeTime, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
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
