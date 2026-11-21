//
//  BVideoPlayPlugin+NetworkHealth.swift
//  ATV-Bilibili
//
//  运行时网络诊断: access log 周期采样、卡顿判定、备选 CDN 测速与换源。
//  只依据真实卡顿换源, 不用 observed/indicated 比特率比（indicated 常是峰值）。
//
//  从 BVideoPlayPlugin.swift 按职责拆出, 逻辑不变。
//

import AVKit
import Foundation

extension BVideoPlayPlugin {
    func startNetworkLogging() {
        guard networkLogTimer == nil else { return }
        networkLogTimer = Timer.scheduledTimer(withTimeInterval: networkLogInterval, repeats: true) { [weak self] _ in
            self?.logNetworkStatus()
        }
    }

    func stopNetworkLogging() {
        networkLogTimer?.invalidate()
        networkLogTimer = nil
    }

    func logNetworkStatus() {
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
    var isUserPaused: Bool {
        playerVC?.player?.timeControlStatus == .paused
    }

    var isWaitingToPlay: Bool {
        playerVC?.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    /// access log 的 indicated 在起播/loading 时常为 0 或负值；日志里的 effective 用流声明平均带宽兜底。
    func effectiveIndicatedBitrate(from accessLogIndicated: Double) -> Double {
        if accessLogIndicated > 0 { return accessLogIndicated }
        guard let declared = playerDelegate?.primaryVideoBandwidth, declared > 0 else { return 0 }
        return Double(declared)
    }

    func bufferedSeconds(of item: AVPlayerItem) -> Double {
        guard let range = item.loadedTimeRanges.first?.timeRangeValue else { return 0 }
        let end = range.start.seconds + range.duration.seconds
        let current = item.currentTime().seconds
        guard end.isFinite, current.isFinite else { return 0 }
        return max(0, end - current)
    }

    /// 只根据真实卡顿触发换源：正在 waiting，或本周期新增了 stall。
    /// 播放流畅时仅 observed < indicated 不触发——indicated 常是峰值，低一些完全正常。
    func checkStallHealth(stallDelta: Int, buffered: Double, currentHost: String) {
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
    func evaluateHostSwitch(currentHost: String, requiredMbps: Double) async {
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
    func switchHost(to host: String) async {
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
}
