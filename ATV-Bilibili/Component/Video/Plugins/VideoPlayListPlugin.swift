//
//  VideoPlayListPlugin.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2024/5/26.
//

import AVKit

class VideoPlayListPlugin: NSObject, CommonPlayerPlugin {
    private let nextActionIdentifierPrefix = "play.next"
    private weak var playerVC: AVPlayerViewController?
    var onPlayEnd: (() -> Void)?
    var onPlayNextWithInfo: ((PlayInfo) -> Void)?
    var onShowCurrentDetail: ((PlayInfo) -> Void)?
    /// 倒序连播：播完一条后往前走而不是往后走
    var isReversed = false

    let sequenceProvider: VideoSequenceProvider?
    /// 队列来源：决定播完是否允许自动推进（推荐流/关注流不允许）
    private let queueKind: PlaybackQueueKind

    @MainActor
    init(sequenceProvider: VideoSequenceProvider?) {
        self.sequenceProvider = sequenceProvider
        queueKind = sequenceProvider?.kind ?? .manualSequence
    }

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
    }

    func playerWillStart(player: AVPlayer) {
        guard let playerVC, let sequenceProvider else { return }
        let menuState = MainActor.assumeIsolated { () -> (PlayInfo?, PlayInfo?) in
            guard sequenceProvider.count > 0 else { return (nil, nil) }
            return (sequenceProvider.peekPrevious(), sequenceProvider.peekNext())
        }
        // 倒序时信息面板里那条按钮指向上一集，文案与图标同步翻转
        let target = isReversed ? menuState.0 : menuState.1
        var actions = playerVC.infoViewActions.filter {
            !$0.identifier.rawValue.hasPrefix(nextActionIdentifierPrefix)
        }

        if let target {
            let action = UIAction(title: isReversed ? VideoPlayerViewController.AutoTriggeredInfoAction.previous.title
                : VideoPlayerViewController.AutoTriggeredInfoAction.next.title,
                image: UIImage(systemName: isReversed ? "backward.end.fill" : "forward.end.fill"),
                identifier: .init(rawValue: "\(nextActionIdentifierPrefix).\(target.sequenceKey)"))
            { [weak self] _ in
                Task { [weak self] in
                    _ = await self?.advance()
                }
            }
            actions.append(action)
        }

        playerVC.infoViewActions = actions
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        var actions = [UIMenuElement]()
        // 推荐流/关注流没有“下一集”的概念，不提供循环整条流的入口。
        if queueKind.allowsAutoAdvance {
            let loopAction = UIAction(title: "循环播放", image: UIImage(systemName: "infinity"), state: Settings.loopPlay ? .on : .off) {
                action in
                action.state = (action.state == .off) ? .on : .off
                Settings.loopPlay = action.state == .on
            }
            actions.append(loopAction)
        }
        let currentInfo = sequenceProvider.map { provider in
            MainActor.assumeIsolated { provider.current() }
        } ?? nil
        if let currentInfo, let onShowCurrentDetail {
            let detailAction = UIAction(title: "查看详情", image: UIImage(systemName: "info.circle")) { _ in
                // 齿轮菜单的 action 回调时 AVKit 自己的菜单正在收起，立即 present 会被系统以
                // "presentation is in progress" 静默吞掉（AI 总结先走网络请求天然错开了收起动画），
                // 等一拍再呈现；呈现本身已验证可用（直调 showDetail 详情页正常浮出）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    onShowCurrentDetail(currentInfo)
                }
            }
            actions.append(detailAction)
        }

        return insertIntoMenu(actions, menu: .moreMenu, current: &current, fallbackToTopLevel: true)
    }

    func playerDidEnd(player: AVPlayer) {
        Task { [weak self] in
            guard let self else { return }
            // 推荐流/关注流播完即止，不进入“下一条”也不触发整条流的循环。
            guard queueKind.allowsAutoAdvance else {
                await MainActor.run { [weak self] in
                    self?.onPlayEnd?()
                }
                return
            }
            let allowsAutoAdvance = SequenceAutoplayPolicy.shouldAutoAdvance(
                continuouslyPlay: Settings.continuouslyPlay,
                kind: queueKind
            )
            if allowsAutoAdvance, await advance() {
                return
            }
            // 只有真的播到序列尽头才回卷。否则（例如关了连播但列表还没播完）
            // 每一集结束都会 reset 回第一集，永远卡在开头。
            guard Settings.loopPlay, !(await canAdvance()) else {
                await MainActor.run { [weak self] in
                    self?.onPlayEnd?()
                }
                return
            }
            await MainActor.run {
                self.sequenceProvider?.reset()
            }
            if !(await advance()) {
                await MainActor.run {
                    player.currentItem?.seek(to: .zero, completionHandler: nil)
                    player.play()
                }
            }
        }
    }

    /// 还能否按当前方向推进。不受连播开关影响，用于判断是否真的播到了序列尽头
    private func canAdvance() async -> Bool {
        await MainActor.run { [weak self] in
            guard let provider = self?.sequenceProvider else { return false }
            return self?.isReversed == true ? provider.hasPrevious : provider.hasNext
        }
    }

    /// 播完一条后按当前方向推进：正序 moveNext，倒序 movePrevious
    @discardableResult
    private func advance() async -> Bool {
        if let next = isReversed ? await sequenceProvider?.movePrevious()
            : await sequenceProvider?.moveNext()
        {
            await MainActor.run { [weak self] in
                self?.onPlayNextWithInfo?(next)
            }
            return true
        }
        return false
    }
}
