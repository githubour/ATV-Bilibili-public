//
//  BLTabBarViewController.swift
//  ATV-Bilibili
//
//  Created by Etan Chen on 2021/4/5.
//

import Kingfisher
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
        showContinueWatchingBannerIfNeeded()
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

    // MARK: - 冷启动「继续观看」横幅

    private var continueBannerShown = false
    private weak var continueBanner: UIView?

    /// 冷启动异步拉一次历史：有「看到一半」的记录就浮出一张续看卡片。每次启动只尝试一次。
    /// 500ms 内拿不到数据就不上横幅，避免首页已就位后再闪出卡片。
    private func showContinueWatchingBannerIfNeeded() {
        guard !continueBannerShown, ApiRequest.isLogin() else { return }
        continueBannerShown = true
        Task { @MainActor in
            guard let item = await Self.firstContinueWatchingItem(timeout: .milliseconds(500)) else { return }
            showContinueWatchingBanner(for: item)
        }
    }

    /// 取历史里第一条「已开始未看完」的记录；超时未返回则放弃（用竞速 group 实现）
    private static func firstContinueWatchingItem(timeout: Duration) async -> HistoryData? {
        await withTaskGroup(of: HistoryData?.self) { group in
            group.addTask {
                guard let list = try? await WebRequest.requestHistory() else { return nil }
                return list.first { $0.progress > 0 && ($0.duration <= 0 || $0.progress < $0.duration) }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func showContinueWatchingBanner(for item: HistoryData) {
        let button = BLButton()
        button.accessibilityLabel = "继续看《\(item.title)》，\(Self.continueSubtitle(for: item))"
        button.onPrimaryAction = { [weak self] _ in
            self?.dismissContinueBanner()
            let detailVC = VideoDetailViewController.create(aid: item.aid, cid: 0)
            detailVC.present(from: UIViewController.topMostViewController(), directlyEnterVideo: true)
        }

        let coverView = UIImageView()
        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.layer.cornerRadius = 10
        coverView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        if let pic = item.pic { coverView.kf.setImage(with: pic) }

        let titleLabel = UILabel()
        titleLabel.text = "继续看《\(item.title)》"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)

        let subLabel = UILabel()
        subLabel.text = Self.continueSubtitle(for: item)
        subLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        subLabel.font = .systemFont(ofSize: 20)

        button.onFocusChanged = { focused in
            // 聚焦时 BLButton 会铺纯白底，白字必须切成深色，否则不可读
            titleLabel.textColor = focused ? .black : .white
            subLabel.textColor = focused ? UIColor.black.withAlphaComponent(0.7) : UIColor.white.withAlphaComponent(0.75)
        }

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subLabel])
        textStack.axis = .vertical
        textStack.spacing = 4

        let contentStack = UIStackView(arrangedSubviews: [coverView, textStack])
        contentStack.axis = .horizontal
        contentStack.spacing = 16
        contentStack.alignment = .center
        contentStack.isUserInteractionEnabled = false
        button.addSubview(contentStack)

        view.addSubview(button)
        continueBanner = button
        button.alpha = 0

        button.snp.makeConstraints { make in
            make.trailing.equalTo(view.safeAreaLayoutGuide).offset(-40)
            make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-40)
            make.width.lessThanOrEqualTo(view.safeAreaLayoutGuide).multipliedBy(0.55)
        }
        contentStack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 28))
        }
        coverView.snp.makeConstraints { make in
            make.width.equalTo(160)
            make.height.equalTo(90)
        }

        UIView.animate(withDuration: 0.25) { button.alpha = 1 }
        // 无人理会就自己退场；但正在聚焦时不要抽走焦点，等焦点离开后再退场
        Task { @MainActor [weak self, weak button] in
            try? await Task.sleep(for: .seconds(20))
            while button?.isFocused == true {
                try? await Task.sleep(for: .seconds(1))
            }
            self?.dismissContinueBanner()
        }
    }

    private static func continueSubtitle(for item: HistoryData) -> String {
        guard item.duration > 0 else { return "继续观看" }
        let remainSeconds = max(item.duration - item.progress, 0) / 1000
        return "继续观看 · 剩 \(max((remainSeconds + 59) / 60, 1)) 分钟"
    }

    private func dismissContinueBanner() {
        guard let banner = continueBanner else { return }
        continueBanner = nil
        UIView.animate(withDuration: 0.2, animations: {
            banner.alpha = 0
        }, completion: { _ in
            banner.removeFromSuperview()
        })
    }
}
