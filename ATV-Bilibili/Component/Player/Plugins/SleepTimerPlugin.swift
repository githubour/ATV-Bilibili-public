//
//  SleepTimerPlugin.swift
//  ATV-Bilibili
//
//  播放器「定时关闭」：到点暂停当前播放并弹窗提示。
//  会话级设置——每个播放器实例独立，不跨视频持久化；换集重建插件后需重新设定。
//

import AVKit
import UIKit

class SleepTimerPlugin: NSObject, CommonPlayerPlugin {
    private struct SleepOption {
        let title: String
        let seconds: TimeInterval?
    }

    private static let options: [SleepOption] = [
        .init(title: "关闭", seconds: nil),
        .init(title: "15 分钟", seconds: 15 * 60),
        .init(title: "30 分钟", seconds: 30 * 60),
        .init(title: "60 分钟", seconds: 60 * 60),
        .init(title: "90 分钟", seconds: 90 * 60),
    ]

    private weak var playerVC: AVPlayerViewController?
    private weak var player: AVPlayer?
    private var timer: Timer?
    private var fireDate: Date?
    private var selectedIndex = 0

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
    }

    func playerDidChange(player: AVPlayer) {
        self.player = player
    }

    func playerDidCleanUp(player: AVPlayer) {
        timer?.invalidate()
        timer = nil
        fireDate = nil
        selectedIndex = 0
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        let actions = Self.options.enumerated().map { index, option in
            UIAction(title: option.title, state: index == selectedIndex ? .on : .off) { [weak self] _ in
                self?.selectOption(at: index)
            }
        }
        // 菜单标题带剩余时间；菜单只在 updateMenus() 时重建，倒计时不是实时刷新的
        let title: String
        if let fireDate, fireDate.timeIntervalSinceNow > 0 {
            let remaining = Int(fireDate.timeIntervalSinceNow.rounded())
            title = String(format: "定时关闭 %d:%02d", remaining / 60, remaining % 60)
        } else {
            title = "定时关闭"
        }
        let menu = UIMenu(title: title,
                          image: UIImage(systemName: "moon.zzz"),
                          options: [.singleSelection],
                          children: actions)
        return [menu]
    }

    private func selectOption(at index: Int) {
        timer?.invalidate()
        timer = nil
        fireDate = nil
        selectedIndex = index
        guard let seconds = Self.options[index].seconds else { return }
        fireDate = Date().addingTimeInterval(seconds)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.fire()
        }
    }

    private func fire() {
        timer = nil
        fireDate = nil
        selectedIndex = 0
        player?.pause()
        playerVC?.presentAlert(title: "定时关闭", message: "时间到，已暂停播放")
    }
}
