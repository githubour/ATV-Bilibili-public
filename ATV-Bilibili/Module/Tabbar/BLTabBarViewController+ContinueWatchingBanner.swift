//
//  BLTabBarViewController+ContinueWatchingBanner.swift
//  ATV-Bilibili
//
//  从 BLTabBarViewController.swift 抽出（2026-10-31 审核行动项），零行为变化。
//

import Kingfisher
import SnapKit
import UIKit

// 冷启动「继续观看」横幅浮层：何时显示/何时让位给播放键提示的决策，加上卡片的构建与退场

extension BLTabBarViewController {
    /// 冷启动异步拉一次历史：有「看到一半」的记录就浮出一张续看卡片。每次启动只尝试一次。
    /// 500ms 内拿不到数据就不上横幅，避免首页已就位后再闪出卡片。
    /// 用户关掉「从上次退出的位置继续播放」后不再上卡片：续看的前提就是续播，否则只会从头播一遍。
    func showContinueWatchingBannerIfNeeded() {
        guard !continueBannerShown else {
            showPlayPauseHintIfNeeded()
            return
        }
        continueBannerShown = true
        guard Settings.continuePlay, ApiRequest.isLogin() else {
            showPlayPauseHintIfNeeded()
            return
        }
        Task { @MainActor [weak self] in
            guard let item = await Self.firstContinueWatchingItem(timeout: .milliseconds(500)) else {
                // 没有续看卡片时才提示播放/暂停键可刷新当前页
                self?.showPlayPauseHintIfNeeded()
                return
            }
            self?.showContinueWatchingBanner(for: item)
        }
    }

    /// 取历史里第一条「已开始未看完」的记录；超时未返回则放弃（用竞速 group 实现）
    private static func firstContinueWatchingItem(timeout: Duration) async -> HistoryData? {
        await withTaskGroup(of: HistoryData?.self) { group in
            group.addTask {
                guard let list = try? await WebRequest.requestHistory() else { return nil }
                return list.first { $0.isResumeCandidate }
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
        button.backgroundEffect = BLGlass.effect()
        button.accessibilityLabel = "继续看《\(item.title)》，\(Self.continueSubtitle(for: item))，按遥控器播放/暂停键继续，或选中这张卡片后按确认键"
        button.onPrimaryAction = { [weak self] _ in
            self?.openContinueWatchingBanner()
        }

        let coverView = UIImageView()
        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.layer.cornerRadius = 10
        coverView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        if let pic = item.pic { coverView.kf.setImage(with: pic, options: .cover(width: 320, height: 180)) }

        let titleLabel = UILabel()
        titleLabel.text = "继续看《\(item.title)》"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)

        let subLabel = UILabel()
        subLabel.text = Self.continueSubtitle(for: item)
        subLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        subLabel.font = .systemFont(ofSize: 20)

        let hintIcon = UIImageView(image: UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)))
        hintIcon.tintColor = UIColor.white.withAlphaComponent(0.9)
        hintIcon.contentMode = .scaleAspectFit

        let hintKeyLabel = UILabel()
        // 卡片默认不抢焦点，所以先把「不用选中也能按」的播放键写清楚；
        // 选中卡片后按确认键同样有效（见 accessibilityLabel）
        hintKeyLabel.text = "按播放/暂停键"
        hintKeyLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        hintKeyLabel.font = .systemFont(ofSize: 18)

        let hintActionLabel = UILabel()
        hintActionLabel.text = "继续播放"
        hintActionLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        hintActionLabel.font = .systemFont(ofSize: 20, weight: .semibold)

        let hintStack = UIStackView(arrangedSubviews: [hintIcon, hintKeyLabel, hintActionLabel])
        hintStack.axis = .vertical
        hintStack.spacing = 4
        hintStack.alignment = .center

        let divider = UIView()
        divider.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        divider.snp.makeConstraints { make in
            make.width.equalTo(1)
            make.height.equalTo(64)
        }

        button.onFocusChanged = { focused in
            // 聚焦时 BLButton 会铺纯白底，白字必须切成深色，否则不可读
            titleLabel.textColor = focused ? .black : .white
            subLabel.textColor = focused ? UIColor.black.withAlphaComponent(0.7) : UIColor.white.withAlphaComponent(0.75)
            hintIcon.tintColor = focused ? .black : UIColor.white.withAlphaComponent(0.9)
            hintKeyLabel.textColor = focused ? UIColor.black.withAlphaComponent(0.7) : UIColor.white.withAlphaComponent(0.75)
            hintActionLabel.textColor = focused ? .black : UIColor.white.withAlphaComponent(0.9)
            divider.backgroundColor = focused ? UIColor.black.withAlphaComponent(0.2) : UIColor.white.withAlphaComponent(0.2)
        }

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subLabel])
        textStack.axis = .vertical
        textStack.spacing = 4

        let contentStack = UIStackView(arrangedSubviews: [coverView, textStack, divider, hintStack])
        contentStack.axis = .horizontal
        contentStack.spacing = 16
        contentStack.alignment = .center
        contentStack.isUserInteractionEnabled = false
        button.addSubview(contentStack)

        view.addSubview(button)
        continueBanner = button
        continueBannerItem = item
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
        guard let minutes = item.remainingMinutes else { return "继续观看" }
        return "继续观看 · 剩 \(minutes) 分钟"
    }

    func openContinueWatchingBanner() {
        guard let item = continueBannerItem else { return }
        dismissContinueBanner()
        let host = UIViewController.topMostViewController()

        // 剧集/课程：直进播放器会走普通稿件播放接口、也容易选错集，
        // 按仓库既有规则（追番/排行榜/合集同款）固定先进详情页选集
        if item.isPgcContent {
            let detailVC: VideoDetailViewController
            if let epid = item.epid, epid > 0 {
                detailVC = VideoDetailViewController.create(epid: epid)
            } else if let seasonId = item.seasonId, seasonId > 0 {
                detailVC = VideoDetailViewController.create(seasonId: seasonId)
            } else {
                detailVC = VideoDetailViewController.create(aid: item.aid, cid: item.resumeCid)
            }
            detailVC.present(from: host, directlyEnterVideo: false)
            return
        }

        // 普通稿件：把历史里的分 P 与断点直接交给详情页，
        // 直进播放器后就不必再靠 pagelist 的第 1P 猜 cid
        let detailVC = VideoDetailViewController.create(aid: item.aid, cid: item.resumeCid)
        detailVC.lastPlayCid = item.resumeCid
        detailVC.playTimeInSecond = item.progress
        detailVC.present(from: host, directlyEnterVideo: true)
    }

    private func dismissContinueBanner() {
        continueBannerItem = nil
        guard let banner = continueBanner else { return }
        continueBanner = nil
        UIView.animate(withDuration: 0.2, animations: {
            banner.alpha = 0
        }, completion: { _ in
            banner.removeFromSuperview()
        })
    }
}
