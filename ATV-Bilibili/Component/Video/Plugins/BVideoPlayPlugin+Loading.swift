//
//  BVideoPlayPlugin+Loading.swift
//  ATV-Bilibili
//
//  装载链路: 起播/换源共用的 playmedia、资源装配（含起播测速）、
//  AVPlayerItem 参数（预缓冲、自动媒体选择关闭）、显示模式匹配判定。
//
//  从 BVideoPlayPlugin.swift 按职责拆出, 逻辑不变。
//

import AVKit
import UIKit

extension BVideoPlayPlugin {
    func startLoad(urlInfo: VideoPlayURLInfo,
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

    func ensureActiveLoad(_ generation: Int) throws -> AVPlayerViewController {
        guard !Task.isCancelled,
              loadGeneration == generation,
              let playerVC
        else {
            throw CancellationError()
        }
        return playerVC
    }

    @MainActor
    func playmedia(urlInfo: VideoPlayURLInfo,
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

    func preparedMedia(urlInfo: VideoPlayURLInfo,
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

    func shouldApplyContentMatch(delegate: BilibiliVideoResourceLoaderDelegate) -> Bool {
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
        // 旧 player 被延迟释放期间必须停下，否则 AVPlayer 会脱离 AVPlayerViewController 继续出声。
        // 函数是 @MainActor 同步体（无 await），首检通过后代次不可能再变，
        // 中间/赋值前的重复 guard 是死分支（2026-11-14 精简）。
        let previousPlayer = playerVC.player
        previousPlayer?.pause()
        previousPlayer?.replaceCurrentItem(with: nil)
        PlayerRetirement.retire(previousPlayer)
        playerVC.player = nil
        playerVC.player = player
        armStartupWatchdog()
    }

    /// 与资源加载器选主视频流的逻辑对齐（共用 BVideoStreamSelection），取出该流各 CDN host 的代表 URL，供起播轻量测速。
    func primaryCDNCandidates(from info: VideoPlayURLInfo, maxQuality: Int?, streamIndex: Int?) -> [String] {
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
}
