//
//  VideoPlayerEpisodeInfoViewController.swift
//  ATV-Bilibili
//
//  播放器信息面板里的「选集」页：与系统的「简介」以及 博主视频/相关视频/互动 并排成一行胶囊，
//  作为 customInfoViewControllers 注册后由 AVKit 统一排版，不再自己绝对定位。
//  内容是一排横向分集卡片，选中即切集继续观看。
//

import AVKit
import UIKit

final class VideoPlayerEpisodeInfoViewController: UIViewController {
    private enum Layout {
        // 与 博主视频/相关视频 面板保持同一套尺寸，切标签时视觉不跳
        static let cardWidth: CGFloat = 320
        static let cardHeight: CGFloat = 248
        static let sectionInsets = NSDirectionalEdgeInsets(top: 28, leading: 32, bottom: 28, trailing: 32)
        static let interGroupSpacing: CGFloat = 28
        static let preferredHeight: CGFloat = 360
    }

    /// 参数为该集在播放序列中的下标
    var onSelectEpisode: ((Int) -> Void)?

    private let entries: [EpisodeEntry]
    private let currentIndex: Int
    /// 本次面板展示期间是否已经进入过列表。
    /// 只在第一次进入时纠正落点，之后用户自己浏览到哪一集就停在哪一集。
    private var hasEnteredList = false
    /// 纠正落点只尝试一次：万一强制聚焦没生效，第二次进入就退回焦点引擎的默认行为，避免"按不下去"
    private var hasAttemptedFocusRedirect = false

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
        // 用户自己浏览过之后，再次进入列表回到他上次停留的那一集
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.alwaysBounceVertical = false
        collectionView.register(EpisodeCardCell.self, forCellWithReuseIdentifier: EpisodeCardCell.reuseIdentifier)
        return collectionView
    }()

    init(entries: [EpisodeEntry], currentIndex: Int) {
        self.entries = entries
        self.currentIndex = currentIndex
        super.init(nibName: nil, bundle: nil)
        title = "选集"
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        anchorCurrentEpisode()
    }

    private var currentIndexPath: IndexPath {
        IndexPath(item: currentIndex, section: 0)
    }

    private var isValidCurrentIndex: Bool {
        entries.indices.contains(currentIndex) &&
            collectionView.numberOfItems(inSection: 0) > currentIndex
    }

    /// 长剧集数多时，先把当前集滚到可见位置，避免从第一集开始一路翻
    private func scrollToCurrentEpisode() {
        guard isValidCurrentIndex else { return }
        collectionView.scrollToItem(at: currentIndexPath, at: .centeredHorizontally, animated: false)
    }

    /// 把当前集滚到可见位置并标记为选中，作为焦点进入列表时的锚点
    private func anchorCurrentEpisode() {
        scrollToCurrentEpisode()
        guard isValidCurrentIndex, !collectionView.isFocused else { return }
        collectionView.selectItem(at: currentIndexPath, animated: false, scrollPosition: [])
    }

    /// 焦点引擎按几何位置挑卡片时（从「选集」标签往下进入），把它拉回到正在播放的那一集
    private func redirectFocusToCurrentEpisode() {
        guard isValidCurrentIndex else { return }
        hasAttemptedFocusRedirect = true
        let target = currentIndexPath
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.collectionView.scrollToItem(at: target, at: .centeredHorizontally, animated: false)
            self.collectionView.setNeedsFocusUpdate()
            self.collectionView.updateFocusIfNeeded()
        }
    }
}

extension VideoPlayerEpisodeInfoViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    /// 光标从「选集」标签往下进入列表时，落点固定为正在播放的那一集。
    /// 否则焦点引擎会按几何位置选中最靠标签（屏幕左侧）的卡片，可能落到当前集前面好几集。
    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        guard entries.indices.contains(currentIndex),
              collectionView.numberOfItems(inSection: 0) > currentIndex
        else { return nil }
        return IndexPath(item: currentIndex, section: 0)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EpisodeCardCell.reuseIdentifier,
                                                            for: indexPath) as? EpisodeCardCell
        else {
            return UICollectionViewCell()
        }
        let entry = entries[indexPath.item]
        cell.isCurrent = entry.sequenceIndex == currentIndex
        cell.update(with: entry)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard entries.indices.contains(indexPath.item) else { return }
        Logger.debug("[episode] 选中第 \(entries[indexPath.item].sequenceIndex + 1) 集")
        onSelectEpisode?(entries[indexPath.item].sequenceIndex)
    }

    /// 从「选集」标签往下第一次进入列表时，焦点引擎是按几何位置选卡片的
    /// （标签在屏幕左侧，于是常落到当前集前面好几集）。这里把这次变更拦下来，
    /// 改成落到正在播放的那一集。
    func collectionView(_ collectionView: UICollectionView,
                        shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool
    {
        guard !hasEnteredList,
              !hasAttemptedFocusRedirect,
              context.previouslyFocusedIndexPath == nil,
              let next = context.nextFocusedIndexPath,
              entries.indices.contains(currentIndex),
              next.item != currentIndex
        else { return true }
        redirectFocusToCurrentEpisode()
        return false
    }

    func collectionView(_ collectionView: UICollectionView,
                        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator)
    {
        if context.nextFocusedIndexPath != nil {
            hasEnteredList = true
        }
    }
}
