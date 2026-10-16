//
//  FollowsViewController.swift
//  ATV-Bilibili
//
//  Created by Etan Chen on 2021/4/4.
//

import SnapKit
import UIKit

final class FollowsViewController: UIViewController, BLTabBarContentVCProtocol {
    private enum LayoutMode {
        case feedFlow
        case grid
    }

    private var currentMode: LayoutMode?
    private var currentContentViewController: UIViewController?

    /// 关注页顶部的 UP 主头像条; 无关注/未登录时高度收 0 不占位
    private let avatarStrip = FollowsAvatarStripView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        avatarStrip.onSelectUp = { [weak self] mid in
            let upSpaceVC = UpSpaceViewController()
            upSpaceVC.mid = mid
            self?.present(upSpaceVC, animated: true)
        }
        view.addSubview(avatarStrip)
        avatarStrip.snp.makeConstraints { make in
            // 顶部悬浮 Tab 胶囊占安全区, 头像条从安全区下沿开始
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.leading.trailing.equalToSuperview()
        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleLayoutModeDidChange),
                                               name: .followsLayoutModeDidChange,
                                               object: nil)
        syncLayoutIfNeeded(force: true)
        avatarStrip.refresh()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncLayoutIfNeeded(force: false)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        currentContentViewController?.preferredFocusEnvironments ?? [view]
    }

    func reloadData() {
        avatarStrip.refresh()
        if let content = currentContentViewController as? BLTabBarContentVCProtocol {
            content.reloadData()
        } else {
            syncLayoutIfNeeded(force: true)
        }
    }

    @objc private func handleLayoutModeDidChange() {
        guard isViewLoaded else { return }
        syncLayoutIfNeeded(force: true)
    }

    private func syncLayoutIfNeeded(force: Bool) {
        let targetMode: LayoutMode = Settings.followsFeedFlowEnabled ? .feedFlow : .grid
        guard force || currentMode != targetMode else { return }

        let targetViewController: UIViewController
        switch targetMode {
        case .feedFlow:
            targetViewController = FollowsFeedFlowViewController()
        case .grid:
            targetViewController = FollowsGridViewController()
        }

        transition(to: targetViewController)
        currentMode = targetMode
    }

    private func transition(to targetViewController: UIViewController) {
        let previousViewController = currentContentViewController
        addChild(targetViewController)
        view.addSubview(targetViewController.view)
        targetViewController.view.snp.makeConstraints { make in
            make.top.equalTo(avatarStrip.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
        targetViewController.didMove(toParent: self)
        currentContentViewController = targetViewController

        guard let previousViewController else { return }
        previousViewController.willMove(toParent: nil)
        previousViewController.view.removeFromSuperview()
        previousViewController.removeFromParent()
    }
}
