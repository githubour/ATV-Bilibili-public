//
//  BVideoPlayPlugin+History.swift
//  ATV-Bilibili
//
//  观看进度上报: 30 秒心跳 + 换集/关闭时的最终上报。
//  旧实现只在 playerDidDismiss 上报, 自动连播/换画质/后台杀进程都会丢进度。
//
//  从 BVideoPlayPlugin.swift 按职责拆出, 逻辑不变。
//

import AVKit
import Foundation

extension BVideoPlayPlugin {
    // MARK: - 观看进度上报

    /// 30 秒心跳 + 换集/关闭时的最终上报。
    /// 旧实现只在 `playerDidDismiss` 上报；自动连播/换画质/后台杀进程都会丢进度。
    func startHistoryReporting() {
        guard reportWatchHistory, historyTimer == nil else { return }
        historyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.reportHistory(force: false)
        }
    }

    func stopHistoryReporting() {
        historyTimer?.invalidate()
        historyTimer = nil
    }

    func reportHistory(force: Bool) {
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
}
