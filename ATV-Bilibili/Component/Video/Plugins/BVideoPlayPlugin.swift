//
//  BVideoPlayPlugin.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2024/5/24.
//
//  B 站视频播放主插件。本文件只保留:
//    会话状态 / 播放器生命周期回调 / 菜单项 / 播放器重建的 generation 闸门。
//  按职责拆出的同目录文件:
//    · BVideoPlayPlugin+History.swift       观看进度心跳与最终上报
//    · BVideoPlayPlugin+NetworkHealth.swift 网络日志、卡顿判定、CDN 测速与换源
//    · BVideoPlayPlugin+Loading.swift       装载链路（playmedia / 资源装配 / 起播）
//    · BVideoPlayPlugin+Recovery.swift      加速回退直连、切画质
//    · BVideoPlayPlugin+Failover.swift      起播/seek 看门狗与编码故障自救
//
//  状态声明仍在主文件, 其他文件通过模块内可见性访问(原 private), 行为不变。
//

import AVKit
import UIKit

class BVideoPlayPlugin: NSObject, CommonPlayerPlugin {
    var onLoadFailure: ((String) -> Void)?

    weak var playerVC: AVPlayerViewController?
    var playerDelegate: BilibiliVideoResourceLoaderDelegate?
    let playInfo: PlayInfo
    let playData: PlayerDetailData
    let reportWatchHistory: Bool
    let minimizeStalling: Bool
    let isMuted: Bool
    let mediaWarmupManager: PlayerMediaWarmupManager?
    var currentPlaybackTime: Double = 0
    // 记录最近一次实际用于加载的 maxQuality/streamIndex，host 切换时原样复用，
    // 不去动用户当前的画质模式（自动多档 fallback 还是手动锁定某一档）
    var lastMaxQuality: Int?
    var lastStreamIndex: Int?

    var networkLogTimer: Timer?
    /// 观看进度心跳与最终上报：连播/换集/后台退出都不再依赖“播放器关闭”这一个时机。
    var historyTimer: Timer?
    var lastHistoryReportAt: Date?
    var lastHistoryReportedSeconds: Double = -1
    var lastStalls = 0
    var lastDroppedFrames = 0
    var cdnProbeReport = ""
    var isProbingCDN = false
    /// 当前会话实际传输模式（创建播放资源时快照；设置只影响新建会话）。
    var transportMode: MediaTransportMode = .direct
    /// 加速不可恢复时的播放器级直连恢复次数（有界，避免无限重试）。
    var acceleratedRecoveryAttempts = 0
    let maxAcceleratedRecoveries = 1
    /// 播放器重建串行闸：切画质/换 host/编码自救/加速回退都走同一条重建链，
    /// 并发进入会互相踩 autoPlayWhenReady 与 generation，导致错位起播。
    var isRebuildingPlayer = false
    /// 单调时钟记录的连续等待起点（systemUptime 秒）。nil 表示当前不在等待。
    /// 日志周期 5s 且需两次不健康采样才计数一次，周期计数实际对应约 120s；
    /// 以单调时长为准，60s 到即回退，不依赖双层计数。
    var acceleratedWaitingSince: TimeInterval?

    /// 加速等待看门狗：isWaiting 为真且非用户暂停时累计单调时长，
    /// 满 60s 触发一次有界直连恢复；任何进展（或用户暂停）即清零。
    /// 由 checkStallHealth 与无 access log 的起播阶段共同驱动。
    func noteAcceleratedWaiting(isWaiting: Bool) {
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
            if now - since >= RecoveryTuning.acceleratedDirectFallbackSeconds {
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
    var stallUnhealthyStreak = 0
    var isEvaluatingHostSwitch = false
    var lastHostSwitchAt: Date?
    var loadTask: Task<Void, Never>?
    var loadGeneration = 0
    /// 起播断点只应用一次。换画质/换 host/换编码各路径已按当前进度 seek，
    /// 若 readyToPlay 时再按 playerStartPos seek 一次，两次远距离 seek 会互相取消 ——
    /// 真机表现为「切格式后进度条倒退」，以及 AVPlayer 卡在 waitingToPlay 不再起播。
    var hasAppliedStartPosition = false
    /// 播放器 timeControlStatus 观察：seek/缓冲卡死最可靠的入口
    var timeControlObservation: NSKeyValueObservation?
    /// 本次装配是否真正出过画面。首次起播的等待交给 startupWatchdog，
    /// 自救看门狗只处理"播过之后再 seek 卡住"的场景，避免打扰正常慢起播。
    var hasStartedPlayback = false

    // ===== 编码格式故障自动切换 =====
    var startupWatchdog: Timer?
    var stallRecoveryWatchdog: Timer?
    var stallRecoveryAttempts = 0
    /// 已试败过的流（"画质id:编码"），防止在坏编码之间来回死循环
    var failedStreamKeys = Set<String>()
    var isCodecFailingOver = false
    var lastCodecSwitchAt: Date?

    /// 播放器恢复链路的全部调参常量，集中一处调参（2026-11-14 收敛）。
    /// 各值的事故背景见使用点注释。
    private enum RecoveryTuning {
        /// 连续几次处于卡顿/等待缓冲才触发，避免单次抖动
        static let stallTriggerCount = 2
        /// 换完 host 后的冷静期：换源重建 AVPlayer 会丢全部已缓冲内容，
        /// 换得太勤本身就制造「每隔一会儿卡一下」（30s → 120s）。
        static let hostSwitchCooldown: TimeInterval = 120
        /// 只有备选实测比当前节点快这么多倍才值得换源，避免在测速噪声上反复横跳
        static let switchSpeedMargin: Double = 1.5
        /// 切编码冷静期，避免 item 报错与看门狗等触发源扎堆连切
        static let codecSwitchCooldown: TimeInterval = 10
        /// 起播看门狗：媒体装配完成后这么久仍未起播（出错/卡死/永远 buffering）视为超时
        static let startupTimeoutSeconds: TimeInterval = 20
        /// seek/换源卡在 waitingToPlay 时的短自救看门狗周期。
        /// 起播看门狗在 playerDidStart 就撤销了，播放中途快进/快退卡住时没有任何计时器在跑。
        static let stallRecoveryDelay: TimeInterval = 8
        static let networkLogInterval: TimeInterval = 5
        /// 加速模式持续等待多久回退直连（单调时钟）
        static let acceleratedDirectFallbackSeconds: TimeInterval = 60
    }

    var stallTriggerCount: Int { RecoveryTuning.stallTriggerCount }
    var hostSwitchCooldown: TimeInterval { RecoveryTuning.hostSwitchCooldown }
    var switchSpeedMargin: Double { RecoveryTuning.switchSpeedMargin }
    var codecSwitchCooldown: TimeInterval { RecoveryTuning.codecSwitchCooldown }
    var startupTimeoutSeconds: TimeInterval { RecoveryTuning.startupTimeoutSeconds }
    var stallRecoveryDelay: TimeInterval { RecoveryTuning.stallRecoveryDelay }
    var networkLogInterval: TimeInterval { RecoveryTuning.networkLogInterval }

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

    func probeCDN() {
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

    func playerDidDismiss(playerVC: AVPlayerViewController) {
        reportHistory(force: true)
        stopHistoryReporting()
    }

    func playerWillCleanUp(playerVC: AVPlayerViewController) {
        invalidatePendingLoad(tearingDown: true)
    }

    func beginLoadGeneration() -> Int {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        return loadGeneration
    }

    func invalidatePendingLoad(tearingDown: Bool) {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        disarmStartupWatchdog()
        playerDelegate = nil
        if tearingDown {
            playerVC = nil
        }
    }
}
