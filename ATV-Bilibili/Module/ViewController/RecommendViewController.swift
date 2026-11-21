import UIKit

/// Keeps the existing recommendation tab stable while switching its presentation.
final class RecommendViewController: UIViewController, BLTabBarContentVCProtocol, ChildContentContainer {
    private var activeMode: Bool?
    /// 子内容铺满整页，容器自身的 view 即承载视图
    var contentView: UIView { view }
    var currentViewController: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        updateContentIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateContentIfNeeded()
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        currentViewController.map { [$0] } ?? super.preferredFocusEnvironments
    }

    func reloadData() {
        forwardReloadToContentViewController()
    }

    private func updateContentIfNeeded() {
        let usesFeedFlow = Settings.recommendFeedFlowEnabled
        guard activeMode != usesFeedFlow else { return }

        // 原实现用 frame + autoresizingMask 铺满，setViewController 的四边约束等价
        setViewController(vc: usesFeedFlow ? FeaturedBrowserViewController() : FeedViewController())
        activeMode = usesFeedFlow
    }
}
