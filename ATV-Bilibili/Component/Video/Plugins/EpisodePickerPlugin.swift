//
//  EpisodePickerPlugin.swift
//  ATV-Bilibili
//
//  播放器内的「选集」入口：注册成 AVPlayerViewController 的 customInfoViewController，
//  由 AVKit 排版成播放器底部信息条的胶囊标签，紧跟在系统「简介」右侧
//  （与 博主视频/相关视频/互动 同一排），面板内容见 VideoPlayerEpisodeInfoViewController。
//
//  生命周期注意：每次换集都会 removeAllPlugins() 后重建插件并重挂视图，
//  因此必须实现 playerWillCleanUp 把自己注册的面板摘掉，否则换一集就堆叠一层。
//

import AVKit
import UIKit

final class EpisodePickerPlugin: NSObject, CommonPlayerPlugin {
    private let infoViewController: VideoPlayerEpisodeInfoViewController
    private weak var playerVC: AVPlayerViewController?

    /// 选中某一集时回调，参数为该集在播放序列中的下标
    var onSelectEpisode: ((Int) -> Void)?

    init(entries: [EpisodeEntry], currentIndex: Int) {
        infoViewController = VideoPlayerEpisodeInfoViewController(entries: entries, currentIndex: currentIndex)
        super.init()
        infoViewController.onSelectEpisode = { [weak self] index in
            self?.onSelectEpisode?(index)
        }
    }

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
        registerInfoViewController()
    }

    func playerWillCleanUp(playerVC: AVPlayerViewController) {
        unregisterInfoViewController()
    }

    // 注意：不要在 playerDidDismiss 里注销。viewDidDisappear 在播放器被全屏页面
    // 临时盖住（播放列表「查看详情」、PiP 收起等）时也会触发，此时注销后没有任何
    // 「重新出现」钩子能把它挂回来，「选集」就会一直消失到下次插件重建（换集/换画质）。
    // 真正的卸载由 playerWillCleanUp 覆盖（removeAllPlugins 必经），足以防换集堆叠。

    /// 插到最前，保证「选集」紧跟系统「简介」；其余面板（博主视频/相关视频/互动）顺序不变
    private func registerInfoViewController() {
        guard let playerVC else { return }
        let others = playerVC.customInfoViewControllers.filter { $0 !== infoViewController }
        playerVC.customInfoViewControllers = [infoViewController] + others
    }

    private func unregisterInfoViewController() {
        playerVC?.customInfoViewControllers.removeAll { $0 === infoViewController }
    }
}
