//
//  CommonPlayerPlugin.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2024/5/25.
//

import AVKit
import UIKit

extension UIMenu.Identifier {
    /// 「播放设置」子菜单（由 SpeedChangerPlugin 创建），只放播放速度
    static let playerSettingMenu = UIMenu.Identifier(rawValue: "setting")
    /// 「更多」齿轮菜单（由 IntroOutroSkipPlugin 创建），CDN 测速/Debug/循环播放/查看详情等挂进它
    static let moreMenu = UIMenu.Identifier(rawValue: "more")
}

protocol CommonPlayerPlugin: NSObject {
    func addViewToPlayerOverlay(container: UIView)
    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement]

    func playerDidLoad(playerVC: AVPlayerViewController)
    func playerDidDismiss(playerVC: AVPlayerViewController)
    func playerWillCleanUp(playerVC: AVPlayerViewController)
    func playerDidChange(player: AVPlayer)
    func playerItemDidChange(playerItem: AVPlayerItem)

    func playerWillStart(player: AVPlayer)
    func playerDidStart(player: AVPlayer)
    func playerDidPause(player: AVPlayer)
    func playerDidEnd(player: AVPlayer)
    func playerDidStall(player: AVPlayer)
    func playerDidFail(player: AVPlayer)
    func playerDidCleanUp(player: AVPlayer)

    /// 进度条/控制栏即将显隐。挂在 contentOverlayView 上的浮层可借此同步淡入淡出。
    /// 注意：回调时机在动画开始之前，插件自行决定是否跟随动画。
    func transportBarVisibilityWillChange(visible: Bool)
}

extension CommonPlayerPlugin {
    func addViewToPlayerOverlay(container: UIView) {}
    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] { return [] }

    /// 把条目挂进指定子菜单（该菜单须由更早注册的插件创建）：命中则就地替换并返回 []（已消化），
    /// 未命中返回 fallback（由调用方决定降级到顶级还是丢弃）。
    /// updateMenus() 在每次换画质/换 CDN 后都会全量重建菜单，本方法每次调用都必须重新挂载。
    func insertIntoMenu(_ items: [UIMenuElement],
                        menu: UIMenu.Identifier,
                        current: inout [UIMenuElement],
                        fallbackToTopLevel: Bool) -> [UIMenuElement]
    {
        if let target = current.compactMap({ $0 as? UIMenu })
            .first(where: { $0.identifier == menu })
        {
            var children = target.children
            children.append(contentsOf: items)
            if let index = current.firstIndex(of: target) {
                current[index] = target.replacingChildren(children)
            }
            return []
        }
        return fallbackToTopLevel ? items : []
    }

    func playerWillStart(player: AVPlayer) {}
    func playerDidStart(player: AVPlayer) {}
    func playerDidPause(player: AVPlayer) {}
    func playerDidEnd(player: AVPlayer) {}
    func playerDidStall(player: AVPlayer) {}
    func playerDidFail(player: AVPlayer) {}
    func playerDidCleanUp(player: AVPlayer) {}

    func playerDidLoad(playerVC: AVPlayerViewController) {}
    func playerDidDismiss(playerVC: AVPlayerViewController) {}
    func playerWillCleanUp(playerVC: AVPlayerViewController) {}
    func playerDidChange(player: AVPlayer) {}
    func playerItemDidChange(playerItem: AVPlayerItem) {}

    func transportBarVisibilityWillChange(visible: Bool) {}
}
