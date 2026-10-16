//
//  NowPlayingSessionPlugin.swift
//  ATV-Bilibili
//
//  iPhone「Apple TV 遥控」的 ±skip 按钮与进度条要同时满足两个条件才渲染:
//  1. 命令受支持: MPRemoteCommandCenter 的命令只有注册了 target/handler 才算
//     "被支持" (WWDC17-251: "If you provide a target-action or a block the
//     command is assumed to be supported"), 只设 preferredIntervals 不算;
//  2. 会话数据完整: AVPlayerViewController 不替应用维护 MPNowPlayingInfoCenter
//     (模拟器实测, 字典里仅剩标题/UP主/封面, 缺时长/进度/倍率), 遥控画不出进度。
//  本插件注册 skip 命令 handler 并补全、周期刷新会话信息, 跳过间隔 15 秒
//  (AVKit 默认 [10])。
//
//  播放/暂停/拖动进度同属媒体会话命令, 同样只有注册了 handler 才生效: 实测
//  播放中(传输栏隐藏)手机端按暂停无效 — 派发到 MPRemoteCommandCenter 的
//  pause 没人接手被直接丢弃; AVKit 只处理自己传输栏 UI 上的操作, 不代管会话
//  命令。会话里发布 rate 之后, 手机端不再发 toggle 而是按当前状态发明确的
//  play/pause, 因此这里把 play/pause/toggle/拖动进度一并注册。
//

import AVKit
import MediaPlayer

class NowPlayingSessionPlugin: NSObject, CommonPlayerPlugin {
    private weak var player: AVPlayer?
    private var refreshTask: Task<Void, Never>?
    private var playHandler: Any?
    private var pauseHandler: Any?
    private var toggleHandler: Any?
    private var positionHandler: Any?
    private var forwardHandler: Any?
    private var backwardHandler: Any?

    func playerDidStart(player: AVPlayer) {
        self.player = player
        installMediaHandlers()
        refreshSessionInfo()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                self?.refreshSessionInfo()
            }
        }
    }

    func playerDidPause(player: AVPlayer) {
        refreshSessionInfo()
    }

    func playerItemDidChange(playerItem: AVPlayerItem) {
        refreshSessionInfo()
    }

    func playerDidCleanUp(player: AVPlayer) {
        refreshTask?.cancel()
        refreshTask = nil
        removeMediaHandlers()
        self.player = nil
        // 退出播放后清掉会话, 避免遥控停留在已结束的视频上
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// 事件优先派发给最后注册的 handler: 我们的实现返回 success, 即使 AVKit
    /// 内部也注册过兜底 handler 也不会重复执行
    private func installMediaHandlers() {
        removeMediaHandlers()
        let commandCenter = MPRemoteCommandCenter.shared()
        playHandler = commandCenter.playCommand.addTarget(handler: { [weak self] _ in
            guard let self, let player = self.player else { return .commandFailed }
            player.play()
            self.refreshSessionInfo()
            return .success
        })
        pauseHandler = commandCenter.pauseCommand.addTarget(handler: { [weak self] _ in
            guard let self, let player = self.player else { return .commandFailed }
            player.pause()
            self.refreshSessionInfo()
            return .success
        })
        toggleHandler = commandCenter.togglePlayPauseCommand.addTarget(handler: { [weak self] _ in
            guard let self, let player = self.player else { return .commandFailed }
            // 缓冲(waitingToPlayAtSpecifiedRate)按"在播"处理, 暂停要能按下去
            if player.timeControlStatus == .paused {
                player.play()
            } else {
                player.pause()
            }
            self.refreshSessionInfo()
            return .success
        })
        positionHandler = commandCenter.changePlaybackPositionCommand.addTarget(handler: { [weak self] event in
            guard let self, let player = self.player,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            player.seek(
                to: CMTime(seconds: positionEvent.positionTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] _ in
                self?.refreshSessionInfo()
            }
            return .success
        })
        forwardHandler = commandCenter.skipForwardCommand.addTarget(handler: { [weak self] event in
            guard let self, let player = self.player else { return .commandFailed }
            return self.skip(player: player, event: event, isForward: true)
        })
        backwardHandler = commandCenter.skipBackwardCommand.addTarget(handler: { [weak self] event in
            guard let self, let player = self.player else { return .commandFailed }
            return self.skip(player: player, event: event, isForward: false)
        })
    }

    private func removeMediaHandlers() {
        let commandCenter = MPRemoteCommandCenter.shared()
        let targets: [(MPRemoteCommand, Any?)] = [
            (commandCenter.playCommand, playHandler),
            (commandCenter.pauseCommand, pauseHandler),
            (commandCenter.togglePlayPauseCommand, toggleHandler),
            (commandCenter.changePlaybackPositionCommand, positionHandler),
            (commandCenter.skipForwardCommand, forwardHandler),
            (commandCenter.skipBackwardCommand, backwardHandler),
        ]
        for (command, handler) in targets {
            if let handler {
                command.removeTarget(handler)
            }
        }
        playHandler = nil
        pauseHandler = nil
        toggleHandler = nil
        positionHandler = nil
        forwardHandler = nil
        backwardHandler = nil
    }

    private func skip(player: AVPlayer, event: MPRemoteCommandEvent, isForward: Bool) -> MPRemoteCommandHandlerStatus {
        // 遥控实际下发的间隔可能与偏好值不同 (WWDC17-251), 以事件携带的为准
        let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? skipIntervalSeconds
        let current = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? .infinity
        let target = isForward ? min(current + interval, duration) : max(current - interval, 0)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            // seek 完成即刷新, 遥控进度条不用等下一个 3s 周期
            self?.refreshSessionInfo()
        }
        return .success
    }

    /// 每 3s 重写会话字典并重申跳过间隔: 前者兜住 seek/倍率/分P切换后的进度漂移,
    /// 后者兜住 AVKit 会话(重)配置时把间隔重置回 [10]
    private func refreshSessionInfo() {
        let intervals = [NSNumber(value: skipIntervalSeconds)]
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipForwardCommand.preferredIntervals = intervals
        commandCenter.skipBackwardCommand.preferredIntervals = intervals

        guard let player else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if let duration = player.currentItem.map({ $0.duration.seconds }),
           duration.isFinite, duration > 0
        {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            // 直播等无确定时长的内容不报时长, 遥控按直播会话处理
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private let skipIntervalSeconds: TimeInterval = 15
}
