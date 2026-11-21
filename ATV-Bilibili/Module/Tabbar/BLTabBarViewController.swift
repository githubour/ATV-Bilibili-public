//
//  BLTabBarViewController.swift
//  ATV-Bilibili
//
//  Created by Etan Chen on 2021/4/5.
//

import SnapKit
import UIKit

protocol BLTabBarContentVCProtocol {
    func reloadData()
}

class BLTabBarViewController: UITabBarController, UITabBarControllerDelegate {
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 与窗口同一层固定深色：各 Tab 页默认不铺底色，日间模式会透出系统浅色底，
        // 白字就压在白底上（用户 2026-11-01 反馈「推荐下方白底白字」）。
        view.backgroundColor = UIColor(white: 0.06, alpha: 1)
        delegate = self
        Settings.bootstrapTabBarPlacementModelIfNeeded()
        NotificationCenter.default.addObserver(self, selector: #selector(handleTabBarPagesDidChange), name: .tabBarPagesDidChange, object: nil)
        VideoDanmakuFilter.shared.autoUpdate()
        TopShelfSyncManager.shared.refresh()
        reloadTabs(animated: false)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // 横幅在场时，播放/暂停键直接续看；其余情况行为保持不变（透传并刷新当前页）
        if continueBannerItem != nil,
           presses.contains(where: { $0.type == .playPause })
        {
            openContinueWatchingBanner()
            return
        }
        super.pressesEnded(presses, with: event)
        guard let buttonPress = presses.first?.type else { return }
        if buttonPress == .playPause {
            if let reloadVC = topMostViewController() as? BLTabBarContentVCProtocol {
                Logger.debug("send reload to \(reloadVC)")
                reloadVC.reloadData()
            }
        }
    }

    // MARK: - 浮层状态（构建/退场逻辑在 +ContinueWatchingBanner / +RefreshHint 两个扩展文件；

    //         存储属性只能放主类，跨文件的扩展要读写，因此不做 private）

    /// 「按播放/暂停键刷新」提示每次启动只显示一次
    var refreshHintShown = false
    /// 冷启动续看横幅：去重闸门 / 在场卡片引用 / 触发续看的条目（播放键拦截用）
    var continueBannerShown = false
    weak var continueBanner: UIView?
    var continueBannerItem: HistoryData?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 先决定要不要浮续看卡片：有卡片时播放/暂停键被卡片占用，
        // 「按此键刷新」提示只在没有卡片时才出现，避免两套提示抢同一个键。
        showContinueWatchingBannerIfNeeded()
    }

    @objc private func handleTabBarPagesDidChange() {
        reloadTabs(animated: false)
    }

    private func reloadTabs(animated: Bool) {
        let previousPage = selectedViewController?.tabBarItem.accessibilityIdentifier
        let pages = Settings.tabBarPages
        let controllers = pages.map { controller(for: $0) }

        setViewControllers(controllers, animated: animated)

        if let previousPage, let index = controllers.firstIndex(where: { $0.tabBarItem.accessibilityIdentifier == previousPage }) {
            selectedIndex = index
        }
    }

    private func controller(for page: TabBarPage) -> UIViewController {
        return TabBarPageVCFactory.createVC(for: page)
    }
}
