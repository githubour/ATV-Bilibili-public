//
//  SpeedChangerPlugin.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2024/5/25.
//

import AVKit

class SpeedChangerPlugin: NSObject, CommonPlayerPlugin {
    /// 速度入口用仪表盘而不是齿轮，更贴近"倍速"语义。
    /// gauge 属 SF Symbols 4（tvOS 16+），取不到时回落到 speedometer。
    private static let speedMenuImage = UIImage(systemName: "gauge") ?? UIImage(systemName: "speedometer")

    private var notifyView: UILabel?
    private weak var containerView: UIView?
    private weak var player: AVPlayer?
    private weak var playerVC: AVPlayerViewController?
    private var hasShownSpeedNotification = false

    @Published private(set) var currentPlaySpeed: PlaySpeed = .default

    func addViewToPlayerOverlay(container: UIView) {
        containerView = container
    }

    private func fadeOutNotifyView() {
        UIView.animate(withDuration: 1.0, animations: {
            self.notifyView?.alpha = 0.0 // Fade out to invisible
        }) { _ in
            self.notifyView?.removeFromSuperview() // Optionally remove from superview after fading out
        }
    }

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC

        currentPlaySpeed = Settings.mediaPlayerSpeed
    }

    func playerDidChange(player: AVPlayer) {
        self.player = player
    }

    func playerWillStart(player: AVPlayer) {
        playerVC?.selectSpeed(AVPlaybackSpeed(rate: currentPlaySpeed.value, localizedName: currentPlaySpeed.name))
    }

    func playerDidStart(player: AVPlayer) {
        guard !hasShownSpeedNotification else { return }
        hasShownSpeedNotification = true

        // 只有在速度不为默认值1时才显示提示
        guard currentPlaySpeed != .default else { return }

        if notifyView == nil {
            notifyView = UILabel()
            notifyView?.backgroundColor = UIColor.black.withAlphaComponent(0.3)
            notifyView?.textColor = UIColor.white
            containerView?.addSubview(notifyView!)
            notifyView?.numberOfLines = 0
            notifyView?.layer.cornerRadius = 10 // Set the corner radius
            notifyView?.layer.masksToBounds = true // Enable masks to bounds
            notifyView?.font = UIFont.systemFont(ofSize: 26)
            notifyView?.textAlignment = NSTextAlignment.center
            notifyView?.snp.makeConstraints { make in
                // make.bottom.equalToSuperview().inset(20) // 20 points from the bottom
                make.center.equalToSuperview() // Center horizontally
                make.width.equalTo(300) // Set a width (optional)
                make.height.equalTo(60) // Set a height (optional)
            }
        }
        notifyView?.isHidden = false
        notifyView?.text = "播放速度设置为 \(currentPlaySpeed.name)"

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.fadeOutNotifyView()
        }
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        let speedActions = PlaySpeed.blDefaults.map { playSpeed in
            UIAction(title: playSpeed.name, state: currentPlaySpeed == playSpeed ? .on : .off) {
                [weak self] _ in
                guard let self else { return }
                player?.currentItem?.audioTimePitchAlgorithm = .timeDomain
                playerVC?.selectSpeed(AVPlaybackSpeed(rate: playSpeed.value, localizedName: playSpeed.name))
                currentPlaySpeed = playSpeed
                // 记住本次选择，下次打开新视频自动沿用（同时更新“默认播放速度”设置项）
                Settings.mediaPlayerSpeed = playSpeed
            }
        }
        let playSpeedMenu = UIMenu(title: "播放速度", options: [.displayInline, .singleSelection], children: speedActions)
        // 「播放速度」是 displayInline 子菜单，标题与图标不显示，
        // 用户在传输栏上看到的就是这一层的图标，所以速度语义的图标挂在父菜单上
        let menu = UIMenu(title: "播放设置", image: Self.speedMenuImage, identifier: .playerSettingMenu, children: [playSpeedMenu])
        return [menu]
    }
}

struct PlaySpeed: Codable {
    var name: String
    var value: Float
}

extension PlaySpeed: Equatable {
    static let `default` = PlaySpeed(name: "1X", value: 1)

    static let blDefaults = [
        PlaySpeed(name: "0.5X", value: 0.5),
        PlaySpeed(name: "0.75X", value: 0.75),
        PlaySpeed(name: "1X", value: 1),
        PlaySpeed(name: "1.25X", value: 1.25),
        PlaySpeed(name: "1.5X", value: 1.5),
        PlaySpeed(name: "1.75X", value: 1.75),
        PlaySpeed(name: "2X", value: 2),
    ]
}
