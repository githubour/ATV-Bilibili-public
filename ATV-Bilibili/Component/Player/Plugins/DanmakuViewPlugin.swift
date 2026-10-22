//
//  DanmakuViewPlugin.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2024/5/23.
//

import AVKit
import Combine
import UIKit

protocol DanmakuProviderProtocol {
    var observerPlayerTime: Bool { get }
    var onSendTextModel: PassthroughSubject<DanmakuTextCellModel, Never> { get }
    func playerTimeChange(time: TimeInterval)
}

class DanmakuViewPlugin: NSObject {
    let danmakuView = DanmakuView()

    init(provider: DanmakuProviderProtocol) {
        danmakuProvider = provider
        super.init()
        provider.onSendTextModel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.shoot($0)
            }.store(in: &cancellable)

        Defaults.shared.$showDanmaku
            .receive(on: DispatchQueue.main)
            .sink {
                [weak self] in
                self?.danmakuView.isHidden = !$0
            }.store(in: &cancellable)
    }

    private let danmakuProvider: DanmakuProviderProtocol
    private var timeObserver: Any?
    private weak var currentPlayer: AVPlayer? // 保存当前 player 的弱引用
    private var cancellable = Set<AnyCancellable>()

    private func shoot(_ model: DanmakuCellModel) {
        // 当显示区域小于1时,将底部弹幕转为浮动弹幕
        if danmakuView.displayArea < 1, model.type == .bottom {
            if let shootModel = model as? DanmakuTextCellModel {
                shootModel.type = .floating
                danmakuView.shoot(danmaku: shootModel)
                return
            }
        }

        danmakuView.shoot(danmaku: model)
    }
}

extension DanmakuViewPlugin: CommonPlayerPlugin {
    func playerDidChange(player: AVPlayer) {
        // 清理旧的 observer（必须用旧的 player 来移除）
        if let timeObserver, let currentPlayer {
            currentPlayer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        // 保存新的 player 引用
        currentPlayer = player

        // 清空当前显示的弹幕，准备重新同步
        danmakuView.clean()
    }

    func playerWillStart(player: AVPlayer) {
        guard danmakuProvider.observerPlayerTime else {
            return
        }

        // 清理旧的 observer（如果有）
        if let timeObserver, let currentPlayer {
            currentPlayer.removeTimeObserver(timeObserver)
        }

        // 保存新的 player 引用
        currentPlayer = player

        // 添加新的 observer 并保存引用。
        // 必须用主队列：provider 的游标/分段字典与 @MainActor 的网络回调共享，
        // 放全局队列会构成并发读写（切集/快进时可能崩溃或串集）。
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                                                      queue: .main)
        { [weak self] time in
            guard let self else { return }
            if !Defaults.shared.showDanmaku { return }
            let seconds = time.seconds
            danmakuProvider.playerTimeChange(time: seconds)
        }
    }

    /// 每次换集都会 removeAllPlugins() 后重建插件，而 danmakuView 是每个实例新建的全屏视图。
    /// 不在这里摘掉的话，连播 N 集就会在 contentOverlayView 上堆 N 层弹幕层。
    /// 用 playerWillCleanUp 而非 playerDidCleanUp：前者无条件调用，后者在 playerVC.player 为 nil 时不会触发。
    func playerWillCleanUp(playerVC: AVPlayerViewController) {
        danmakuView.stop()
        danmakuView.clean()
        danmakuView.removeFromSuperview()
    }

    func playerDidCleanUp(player: AVPlayer) {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        currentPlayer = nil
    }

    func addViewToPlayerOverlay(container: UIView) {
        container.addSubview(danmakuView)
        danmakuView.makeConstraintsToBindToSuperview()
        danmakuView.setNeedsLayout()
        danmakuView.layoutIfNeeded()
        danmakuView.paddingTop = 5
        danmakuView.trackHeight = 50
        danmakuView.displayArea = Settings.danmakuArea.percent
        // 同屏上限：轨道按 50pt 高度铺满整屏也就 20 余条浮动轨，正常密度根本到不了 100；
        // 只有爆款稿件的弹幕潮会冲破，此时宁可少入场几条，也不要让同屏 CALayer 堆到几百个拖慢播放
        danmakuView.maxOnScreenCount = 100
        danmakuView.recaculateTracks()
    }

    func playerDidStart(player: AVPlayer) {
        danmakuView.play()
    }

    func playerDidPause(player: AVPlayer) {
        danmakuView.pause()
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        let danmakuImage = UIImage(systemName: "list.bullet.rectangle.fill")
        let danmakuImageDisable = UIImage(systemName: "list.bullet.rectangle")
        let danmakuAction = UIAction(title: "显示弹幕", image: danmakuView.isHidden ? danmakuImageDisable : danmakuImage) {
            action in
            Defaults.shared.toggleShowDanmaku()
            action.image = Defaults.shared.showDanmaku ? danmakuImage : danmakuImageDisable
        }
        let danmakuDurationMenu = UIMenu(title: "弹幕展示时长", options: [.displayInline, .singleSelection], children: [4, 6, 8].map { dur in
            UIAction(title: "\(dur) 秒", state: dur == Settings.danmakuDuration ? .on : .off) { _ in Settings.danmakuDuration = dur }
        })
        let danmakuSizeMenu = UIMenu(title: "弹幕字号", options: [.displayInline, .singleSelection], children: DanmakuSize.allCases.map { size in
            UIAction(title: size.title, state: size == Settings.danmakuSize ? .on : .off) { _ in Settings.danmakuSize = size }
        })
        let danmakuAILevelMenu = UIMenu(title: "弹幕屏蔽等级", options: [.displayInline, .singleSelection], children: [Int32](1...10).map { level in
            UIAction(title: "\(level)", state: level == Settings.danmakuAILevel ? .on : .off) { _ in Settings.danmakuAILevel = level }
        })
        let danmakuSettingMenu = UIMenu(title: "弹幕设置", image: UIImage(systemName: "keyboard.badge.ellipsis"), children: [danmakuDurationMenu, danmakuSizeMenu, danmakuAILevelMenu])

        return [danmakuAction, danmakuSettingMenu]
    }
}
