//
//  BVideoPlayPlugin+Failover.swift
//  ATV-Bilibili
//
//  自救看门狗: 起播超时、seek/取流卡死重试、同画质换编码（优先 AVC）。
//
//  从 BVideoPlayPlugin.swift 按职责拆出, 逻辑不变。
//

import AVKit
import Foundation

extension BVideoPlayPlugin {
    // MARK: - 编码格式故障自动切换

    func armStartupWatchdog() {
        disarmStartupWatchdog()
        startupWatchdog = Timer.scheduledTimer(withTimeInterval: startupTimeoutSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startupWatchdogFired()
            }
        }
    }

    func disarmStartupWatchdog() {
        startupWatchdog?.invalidate()
        startupWatchdog = nil
    }

    // MARK: - seek 卡死自救

    func playerTimeControlStatusDidChange(_ player: AVPlayer) {
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

    func armStallRecoveryWatchdog() {
        disarmStallRecoveryWatchdog()
        stallRecoveryWatchdog = Timer.scheduledTimer(withTimeInterval: stallRecoveryDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stallRecoveryFired()
            }
        }
    }

    func disarmStallRecoveryWatchdog() {
        stallRecoveryWatchdog?.invalidate()
        stallRecoveryWatchdog = nil
    }

    @MainActor
    func stallRecoveryFired() {
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
    func startupWatchdogFired() {
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
    func effectiveStream() -> VideoPlayURLInfo.DashInfo.DashMediaInfo? {
        BVideoStreamSelection.select(videos: playData.videoPlayURLInfo.dash.video,
                                     streamIndex: lastStreamIndex,
                                     maxQuality: lastMaxQuality).first
    }

    /// 同一画质档位下换一个编码：优先 AVC（解码兼容性最好），已试败过的跳过
    func codecFailoverStreamIndex(after current: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> Int? {
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
    func attemptCodecFailover(reason: String, fallbackMessage: String? = nil) async {
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
