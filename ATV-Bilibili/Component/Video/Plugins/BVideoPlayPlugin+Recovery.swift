//
//  BVideoPlayPlugin+Recovery.swift
//  ATV-Bilibili
//
//  播放器级恢复: 加速传输不可恢复时的有限直连回退、用户切画质。
//  两条路径都复用同一套 generation 闸门与「先记播放意图再重建」的保护。
//
//  从 BVideoPlayPlugin.swift 按职责拆出, 逻辑不变。
//

import AVKit
import Foundation

extension BVideoPlayPlugin {
    /// 加速传输不可恢复时的有限直连恢复：记录播放时间与用户暂停意图，
    /// 取消旧会话、创建新的直连资源、恢复位置。复用 generation 与播放意图保护。
    @MainActor
    func recoverAcceleratedToDirect() async {
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
}
