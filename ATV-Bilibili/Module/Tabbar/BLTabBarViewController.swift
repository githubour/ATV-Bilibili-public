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
        delegate = self
        Settings.bootstrapTabBarPlacementModelIfNeeded()
        NotificationCenter.default.addObserver(self, selector: #selector(handleTabBarPagesDidChange), name: .tabBarPagesDidChange, object: nil)
        VideoDanmakuFilter.shared.autoUpdate()
        TopShelfSyncManager.shared.refresh()
        reloadTabs(animated: false)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        guard let buttonPress = presses.first?.type else { return }
        if buttonPress == .playPause {
            if let reloadVC = topMostViewController() as? BLTabBarContentVCProtocol {
                Logger.debug("send reload to \(reloadVC)")
                reloadVC.reloadData()
            }
        }
    }

    // MARK: - 播放/暂停键刷新提示

    private var refreshHintShown = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showPlayPauseHintIfNeeded()
    }

    /// 主页左下角短暂显示「按播放/暂停键刷新」提示, 每次启动只显示一次
    private func showPlayPauseHintIfNeeded() {
        guard !refreshHintShown else { return }
        refreshHintShown = true

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        guard let icon = UIImage(systemName: "playpause", withConfiguration: symbolConfig) else { return }

        let hintView = UIView()
        hintView.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        hintView.layer.cornerRadius = 10
        hintView.isUserInteractionEnabled = false

        let imageView = UIImageView(image: icon)
        imageView.tintColor = .white
        imageView.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = "按此键刷新"
        label.textColor = .white
        label.font = .systemFont(ofSize: 24, weight: .medium)

        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center

        hintView.addSubview(stack)
        view.addSubview(hintView)
        hintView.alpha = 0

        hintView.snp.makeConstraints { make in
            make.leading.equalTo(view.safeAreaLayoutGuide).offset(40)
            make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-40)
        }
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 20))
        }

        UIView.animate(withDuration: 0.25) {
            hintView.alpha = 1
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            UIView.animate(withDuration: 0.4, animations: {
                hintView.alpha = 0
            }, completion: { _ in
                hintView.removeFromSuperview()
            })
        }
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
