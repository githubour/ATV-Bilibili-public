//
//  MaskViewPlugin.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2024/5/25.
//

import AVKit
import Combine
import UIKit

class MaskViewPlugin: NSObject, CommonPlayerPlugin {
    weak var maskView: UIView?
    var maskProvider: MaskProvider
    private var observer: Any?
    private weak var player: AVPlayer?
    private var cancellable: AnyCancellable?
    /// 防挡与弹幕展示共用一个开关：弹幕关闭的会话不下载遮罩流、不挂逐帧观察者
    private var showDanmaku = Defaults.shared.showDanmaku

    init(maskView: UIView, maskProvider: MaskProvider) {
        self.maskView = maskView
        self.maskProvider = maskProvider
        super.init()
        // 播放中途开关弹幕时同步增删观察者（BMaskProvider 的下载由首次 getMask 懒触发）
        cancellable = Defaults.shared.$showDanmaku
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                guard let self else { return }
                showDanmaku = show
                if show {
                    if let player { installObserver(on: player) }
                } else {
                    removeObserver(from: player)
                }
            }
    }

    func playerDidChange(player: AVPlayer) {
        // 旧观察者必须用旧 player 移除；原先直接覆盖 token，换 player 会泄漏旧观察者
        removeObserver(from: self.player)
        self.player = player
        if showDanmaku {
            installObserver(on: player)
        }
    }

    func playerDidCleanUp(player: AVPlayer) {
        removeObserver(from: player)
        self.player = nil
    }

    private func installObserver(on player: AVPlayer) {
        guard observer == nil else { return }
        let timePerFrame = CMTime(value: 1, timescale: CMTimeScale(maskProvider.preferFPS()))
        observer = player.addPeriodicTimeObserver(forInterval: timePerFrame, queue: .main) {
            [weak self] time in
            guard let self, let maskView, !maskView.isHidden else { return }
            maskProvider.getMask(for: time, frame: maskView.frame) {
                [weak maskView] maskLayer in
                maskView?.layer.mask = maskLayer
            }
        }
    }

    private func removeObserver(from player: AVPlayer?) {
        // player 已释放时 token 随之失效，只剩置空
        if let observer, let player {
            player.removeTimeObserver(observer)
        }
        observer = nil
    }
}
