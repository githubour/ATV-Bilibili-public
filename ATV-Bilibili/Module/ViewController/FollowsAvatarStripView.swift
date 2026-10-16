//
//  FollowsAvatarStripView.swift
//  ATV-Bilibili
//
//  Created by ATV-Bilibili contributors on 2026/10/11.
//

import SnapKit
import UIKit

/// 关注页顶部的 UP 主头像横滑条。数据与「我的-关注列表」同源 (requestFollowing), 分页状态机收编在 PagedProvider。
final class FollowsAvatarStripView: UIView {
    var onSelectUp: ((Int) -> Void)?

    private let stripHeight: CGFloat = 200
    private let avatarSize: CGFloat = 104
    private var heightConstraint: Constraint?

    private lazy var provider = PagedProvider<WebRequest.FollowingUser>(
        fetch: { try await WebRequest.requestFollowing(page: $0) },
        dedupKey: { $0.mid },
        prefetchMargin: 4
    )

    private lazy var collectionView: UICollectionView = {
        let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(150), heightDimension: .absolute(stripHeight))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = 28
        // 垂直呼吸空间放在 cell 内部: section 的垂直 contentInsets 会叠加在组高之外, 溢出条高被裁剪
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 90, bottom: 0, trailing: 90)
        let layout = UICollectionViewCompositionalLayout(section: section)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.clipsToBounds = false
        // 条已挂在安全区之下, 再吃一次 adjustedContentInset 会把头像压出条外
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FollowUpAvatarCell.self)
        return collectionView
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(collectionView)
        collectionView.makeConstraintsToBindToSuperview()
        snp.makeConstraints { make in
            heightConstraint = make.height.equalTo(0).constraint
        }
        provider.onItemsChange = { [weak self] in
            self?.updateHeight()
            self?.collectionView.reloadData()
        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAccountUpdate),
                                               name: AccountManager.didUpdateNotification,
                                               object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 拉取第一页关注列表并整体替换; 账号切换/播放暂停键刷新都会走到这里
    func refresh() {
        provider.refresh()
    }

    @objc private func handleAccountUpdate() {
        refresh()
    }

    /// 无关注/未登录: 整条收起(高度 0 + 隐藏), 焦点引擎不会探到被隐藏的格子
    private func updateHeight() {
        let target: CGFloat = provider.items.isEmpty ? 0 : stripHeight
        collectionView.isHidden = provider.items.isEmpty
        heightConstraint?.update(offset: target)
    }
}

extension FollowsAvatarStripView: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return provider.items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeue(FollowUpAvatarCell.self, for: indexPath)
        let data = provider.items[indexPath.item]
        cell.configure(name: data.uname, face: data.face)
        return cell
    }
}

extension FollowsAvatarStripView: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelectUp?(provider.items[indexPath.item].mid)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        provider.loadMoreIfNeeded(atIndex: indexPath.item)
    }
}
