//
//  VideoPlayerActionInfoViewController.swift
//  ATV-Bilibili
//
//  Created by OpenAI on 2026/4/5.
//

import AVKit
import UIKit

final class VideoPlayerInfoActionCell: BLMotionCollectionViewCell {
    struct ViewModel: Hashable {
        let title: String
        let valueText: String
        let imageName: String
        let selectedImageName: String
        let isOn: Bool
    }

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let focusedBackgroundView = UIView()
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private var viewModel: ViewModel?

    override func setup() {
        super.setup()
        scaleFactor = 1.08
        contentView.addSubview(blurView)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.layer.cornerRadius = 18
        blurView.layer.cornerCurve = .continuous
        blurView.clipsToBounds = true

        focusedBackgroundView.backgroundColor = .white
        focusedBackgroundView.isHidden = true
        blurView.contentView.addSubview(focusedBackgroundView)
        focusedBackgroundView.translatesAutoresizingMaskIntoConstraints = false

        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        imageView.contentMode = .scaleAspectFit
        blurView.contentView.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        blurView.contentView.addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .systemFont(ofSize: 24, weight: .medium)
        valueLabel.textAlignment = .center
        valueLabel.numberOfLines = 1
        blurView.contentView.addSubview(valueLabel)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: contentView.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            focusedBackgroundView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
            focusedBackgroundView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),
            focusedBackgroundView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
            focusedBackgroundView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor),

            imageView.centerXAnchor.constraint(equalTo: blurView.contentView.centerXAnchor),
            imageView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 34),
            imageView.widthAnchor.constraint(equalToConstant: 54),
            imageView.heightAnchor.constraint(equalToConstant: 54),

            titleLabel.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -18),
            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 18),

            valueLabel.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 18),
            valueLabel.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -18),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            valueLabel.bottomAnchor.constraint(lessThanOrEqualTo: blurView.contentView.bottomAnchor, constant: -24),
        ])
    }

    func update(viewModel: ViewModel) {
        self.viewModel = viewModel
        titleLabel.text = viewModel.title
        valueLabel.text = viewModel.valueText
        updateAppearance()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        updateAppearance()
    }

    private func updateAppearance() {
        guard let viewModel else { return }
        focusedBackgroundView.isHidden = !isFocused
        let iconName = viewModel.isOn ? viewModel.selectedImageName : viewModel.imageName
        imageView.image = UIImage(systemName: iconName)
        let foregroundColor: UIColor = isFocused ? .black : .white
        imageView.tintColor = foregroundColor
        titleLabel.textColor = foregroundColor
        valueLabel.textColor = isFocused ? UIColor.black.withAlphaComponent(0.85) : UIColor.white.withAlphaComponent(0.8)
    }
}

final class VideoPlayerActionInfoViewController: UIViewController {
    private enum Layout {
        static let cardWidth: CGFloat = 260
        static let cardHeight: CGFloat = 210
        static let sectionInsets = NSDirectionalEdgeInsets(top: 28, leading: 32, bottom: 28, trailing: 32)
        static let interGroupSpacing: CGFloat = 24
        static let preferredHeight: CGFloat = 320
    }

    enum ActionKind: Hashable {
        case follow
        case like
        case coin
        case favorite

        var title: String {
            switch self {
            case .follow:
                return "关注博主"
            case .like:
                return "点赞视频"
            case .coin:
                return "投币"
            case .favorite:
                return "收藏视频"
            }
        }

        var imageName: String {
            switch self {
            case .follow:
                return "heart"
            case .like:
                return "hand.thumbsup"
            case .coin:
                return "bitcoinsign.circle"
            case .favorite:
                return "star"
            }
        }

        var selectedImageName: String {
            switch self {
            case .follow:
                return "heart.fill"
            case .like:
                return "hand.thumbsup.fill"
            case .coin:
                return "bitcoinsign.circle.fill"
            case .favorite:
                return "star.fill"
            }
        }
    }

    private struct Entry: Hashable {
        let kind: ActionKind
        var isOn: Bool
        var valueText: String
        var countValue: Int?
    }

    private let aid: Int
    private let ownerMid: Int
    private var entries: [Entry]
    private var inFlightKinds = Set<ActionKind>()
    private var locallyMutatedKinds = Set<ActionKind>()
    /// 本视频已投硬币倍数(0/1/2)，上限 2；进入面板时从服务端加载
    private var coinMultiply = 0

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                  heightDimension: .fractionalHeight(1.0))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(widthDimension: .absolute(Layout.cardWidth),
                                                   heightDimension: .absolute(Layout.cardHeight))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = Layout.sectionInsets
            section.interGroupSpacing = Layout.interGroupSpacing
            section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
            return section
        }

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.alwaysBounceVertical = false
        collectionView.register(VideoPlayerInfoActionCell.self)
        return collectionView
    }()

    init(detail: VideoDetail?) {
        aid = detail?.View.aid ?? 0
        ownerMid = detail?.View.owner.mid ?? 0
        let followerText = "\((detail?.Card.follower ?? 0).numberString())粉丝"
        let likeCount = detail?.View.stat.like ?? 0
        let favoriteCount = detail?.View.stat.favorite ?? 0
        entries = [
            Entry(kind: .follow, isOn: detail?.Card.following ?? false, valueText: followerText, countValue: nil),
            Entry(kind: .like, isOn: false, valueText: likeCount.numberString(), countValue: likeCount),
            Entry(kind: .coin, isOn: false, valueText: (detail?.View.stat.coin ?? 0).numberString(), countValue: detail?.View.stat.coin ?? 0),
            Entry(kind: .favorite, isOn: false, valueText: favoriteCount.numberString(), countValue: favoriteCount),
        ]
        super.init(nibName: nil, bundle: nil)
        title = "互动"
        loadRemoteStatesIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 0, height: Layout.preferredHeight)
        view.backgroundColor = .clear
        view.addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func loadRemoteStatesIfNeeded() {
        guard aid > 0 else { return }
        Task { [weak self] in
            guard let aid = self?.aid else { return }
            async let liked = WebRequest.requestLikeStatus(aid: aid)
            async let coinMulti = WebRequest.requestCoinStatus(aid: aid)
            async let favorited = WebRequest.requestFavoriteStatus(aid: aid)
            let (isLiked, multiply, isFavorited) = await(liked, coinMulti, favorited)
            await MainActor.run {
                self?.coinMultiply = multiply
                self?.applyRemoteState(for: .like, isOn: isLiked)
                self?.applyRemoteState(for: .coin, isOn: multiply > 0)
                self?.applyRemoteState(for: .favorite, isOn: isFavorited)
            }
        }
    }

    private func applyRemoteState(for kind: ActionKind, isOn: Bool) {
        guard !inFlightKinds.contains(kind),
              !locallyMutatedKinds.contains(kind)
        else {
            return
        }
        updateState(for: kind, isOn: isOn)
    }

    private func updateState(for kind: ActionKind, isOn: Bool) {
        guard let index = entries.firstIndex(where: { $0.kind == kind }) else { return }
        entries[index].isOn = isOn
        if isViewLoaded {
            collectionView.reloadData()
        }
    }

    private func updateCount(for kind: ActionKind, delta: Int) {
        guard let index = entries.firstIndex(where: { $0.kind == kind }) else { return }
        let currentCount = entries[index].countValue ?? 0
        let nextCount = max(0, currentCount + delta)
        entries[index].countValue = nextCount
        entries[index].valueText = nextCount.numberString()
    }

    private func handleFollow() {
        guard ownerMid > 0,
              let index = entries.firstIndex(where: { $0.kind == .follow })
        else { return }

        entries[index].isOn.toggle()
        collectionView.reloadData()
        let follow = entries[index].isOn
        Task { @MainActor [weak self] in
            do {
                try await WebRequest.follow(mid: ownerMid, follow: follow)
            } catch {
                // 失败回滚 + 提示，避免图标停在错误状态
                guard let self else { return }
                self.entries[index].isOn = !follow
                self.collectionView.reloadData()
                self.presentAlert(title: follow ? "关注失败" : "取消关注失败",
                                  message: error.localizedDescription)
            }
        }
    }

    private func handleLike() {
        guard aid > 0,
              !inFlightKinds.contains(.like),
              let index = entries.firstIndex(where: { $0.kind == .like })
        else { return }

        inFlightKinds.insert(.like)
        locallyMutatedKinds.insert(.like)
        let previous = entries[index]
        entries[index].isOn.toggle()
        updateCount(for: .like, delta: entries[index].isOn ? 1 : -1)
        collectionView.reloadData()

        let nextState = entries[index].isOn
        Task { [weak self] in
            guard let self else { return }
            let failure: String?
            do {
                try await WebRequest.requestLike(aid: self.aid, like: nextState)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                self.inFlightKinds.remove(.like)
                guard let failure else { return }
                if let rollbackIndex = self.entries.firstIndex(where: { $0.kind == .like }) {
                    self.entries[rollbackIndex] = previous
                    self.collectionView.reloadData()
                }
                self.presentAlert(title: "点赞失败", message: failure)
            }
        }
    }

    /// 投币：上限 2 枚/视频，投币同时自动点赞（requestCoin select_like=1）
    private func handleCoin() {
        guard aid > 0, !inFlightKinds.contains(.coin) else { return }
        guard coinMultiply < 2 else {
            presentAlert(title: "投币", message: "这个视频已经投过 2 枚硬币啦")
            return
        }
        guard let presenter = activePresenterForFavoritePicker() else { return }

        let alert = UIAlertController(title: "投币个数", message: "投币会同时为视频点赞", preferredStyle: .actionSheet)
        for num in 1...2 where coinMultiply + num <= 2 {
            alert.addAction(UIAlertAction(title: "\(num)", style: .default) { [weak self] _ in
                guard let self else { return }
                self.locallyMutatedKinds.insert(.coin)
                self.coinMultiply += num
                if let index = self.entries.firstIndex(where: { $0.kind == .coin }) {
                    self.entries[index].isOn = true
                    self.updateCount(for: .coin, delta: num)
                    self.collectionView.reloadData()
                }
                Task { [weak self] in
                    do {
                        try await WebRequest.requestCoin(aid: self?.aid ?? 0, num: num)
                    } catch {
                        await MainActor.run {
                            guard let self else { return }
                            self.coinMultiply -= num
                            if let index = self.entries.firstIndex(where: { $0.kind == .coin }) {
                                self.entries[index].isOn = self.coinMultiply >= 2
                                self.updateCount(for: .coin, delta: -num)
                                self.collectionView.reloadData()
                            }
                            self.presentAlert(title: "投币失败", message: error.localizedDescription)
                        }
                    }
                }
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presenter.present(alert, animated: true)
    }

    private func handleFavorite() {
        guard aid > 0, !inFlightKinds.contains(.favorite) else { return }
        inFlightKinds.insert(.favorite)

        Task { [weak self] in
            guard let self else { return }
            guard let favList = try? await WebRequest.requestFavVideosList() else {
                _ = await MainActor.run {
                    self.inFlightKinds.remove(.favorite)
                }
                return
            }

            await MainActor.run {
                if let index = self.entries.firstIndex(where: { $0.kind == .favorite }),
                   self.entries[index].isOn
                {
                    self.locallyMutatedKinds.insert(.favorite)
                    self.entries[index].isOn = false
                    self.updateCount(for: .favorite, delta: -1)
                    self.collectionView.reloadData()
                    self.inFlightKinds.remove(.favorite)
                    let aid = self.aid
                    let folderIDs = favList.map(\.id)
                    Task { [weak self] in
                        do {
                            try await WebRequest.removeFavorite(aid: aid, mid: folderIDs)
                        } catch {
                            await MainActor.run {
                                guard let self else { return }
                                if let i = self.entries.firstIndex(where: { $0.kind == .favorite }), self.entries[i].isOn == false {
                                    self.entries[i].isOn = true
                                    self.updateCount(for: .favorite, delta: 1)
                                    self.collectionView.reloadData()
                                }
                                self.presentAlert(title: "取消收藏失败", message: error.localizedDescription)
                            }
                        }
                    }
                    return
                }

                self.presentFavoritePicker(favList: favList)
            }
        }
    }

    private func presentFavoritePicker(favList: [FavListData]) {
        guard let presenter = activePresenterForFavoritePicker() else {
            inFlightKinds.remove(.favorite)
            return
        }

        let alert = UIAlertController(title: "收藏", message: nil, preferredStyle: .actionSheet)
        for fav in favList {
            alert.addAction(UIAlertAction(title: fav.title, style: .default) { [weak self] _ in
                guard let self else { return }
                if let index = self.entries.firstIndex(where: { $0.kind == .favorite }) {
                    self.locallyMutatedKinds.insert(.favorite)
                    self.entries[index].isOn = true
                    self.updateCount(for: .favorite, delta: 1)
                    self.collectionView.reloadData()
                }
                self.inFlightKinds.remove(.favorite)
                let aid = self.aid
                Task { [weak self] in
                    do {
                        try await WebRequest.requestFavorite(aid: aid, mid: fav.id)
                    } catch {
                        await MainActor.run {
                            guard let self else { return }
                            if let i = self.entries.firstIndex(where: { $0.kind == .favorite }), self.entries[i].isOn {
                                self.entries[i].isOn = false
                                self.updateCount(for: .favorite, delta: -1)
                                self.collectionView.reloadData()
                            }
                            self.presentAlert(title: "收藏失败", message: error.localizedDescription)
                        }
                    }
                }
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.inFlightKinds.remove(.favorite)
        })

        presenter.present(alert, animated: true)
    }

    private func activePresenterForFavoritePicker() -> UIViewController? {
        guard isViewLoaded, view.window != nil else { return nil }
        var presenter: UIViewController = self
        while let parent = presenter.parent, parent.viewIfLoaded?.window != nil {
            presenter = parent
        }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        return presenter
    }
}

extension VideoPlayerActionInfoViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let entry = entries[indexPath.item]
        let cell = collectionView.dequeue(VideoPlayerInfoActionCell.self, for: indexPath)
        cell.update(viewModel: .init(title: entry.kind.title,
                                     valueText: entry.valueText,
                                     imageName: entry.kind.imageName,
                                     selectedImageName: entry.kind.selectedImageName,
                                     isOn: entry.isOn))
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let entry = entries[indexPath.item]
        switch entry.kind {
        case .follow:
            handleFollow()
        case .like:
            handleLike()
        case .coin:
            handleCoin()
        case .favorite:
            handleFavorite()
        }
    }
}
