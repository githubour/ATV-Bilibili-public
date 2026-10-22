//
//  UIViewController+ChildContent.swift
//  ATV-Bilibili
//
//  「左侧列表 + 右侧内容区」这类容器 VC 的公共换入逻辑。
//  分类侧栏、个人页侧栏、分段控制原先各复制了一份完全相同的 setViewController。
//

import UIKit

/// 容器 VC 只需提供内容承载视图和当前子控制器引用，换入换出由扩展统一实现
protocol ChildContentContainer: UIViewController {
    var contentView: UIView { get }
    var currentViewController: UIViewController? { get set }
}

extension ChildContentContainer {
    /// 用 vc 整体替换右侧内容区：先摘掉旧子控制器，再把新视图绑定到 contentView 四边
    func setViewController(vc: UIViewController) {
        currentViewController?.willMove(toParent: nil)
        currentViewController?.view.removeFromSuperview()
        currentViewController?.removeFromParent()

        currentViewController = vc
        addChild(vc)
        contentView.addSubview(vc.view)
        vc.view.makeConstraintsToBindToSuperview()
        vc.didMove(toParent: self)
    }

    /// 把刷新请求转发给当前内容子控制器
    func forwardReloadToContentViewController() {
        (currentViewController as? BLTabBarContentVCProtocol)?.reloadData()
    }
}
