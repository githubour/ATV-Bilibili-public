//
//  CategoryViewController.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2023/2/26.
//

import Foundation
import UIKit

class CategoryViewController: UIViewController, BLTabBarContentVCProtocol, ChildContentContainer {
    struct CategoryDisplayModel {
        let title: String
        let contentVC: UIViewController
        var autoSelect: Bool? = true
    }

    var typeCollectionView: UICollectionView!
    var categories = [CategoryDisplayModel]()
    let contentView = UIView()
    weak var currentViewController: UIViewController?
    /// 分类为空时展示的文案（收藏页/排行榜可覆盖）
    var emptyStateText = "暂无内容"
    private lazy var emptyLabel = UILabel.emptyState(emptyStateText)

    /// 左侧分类侧栏宽度：排行榜这类两字短标题分类收窄给内容区让位，收藏页标题是收藏夹名可能很长，保持宽侧栏
    var sidebarWidth: CGFloat { 500 }

    override func viewDidLoad() {
        super.viewDidLoad()
        if !categories.isEmpty {
            initTypeCollectionView()
        }
    }

    func initTypeCollectionView() {
        // 收藏页在"没有收藏夹 / 请求失败"时也会走到这里；空分类下
        // 强制选中 index 0 会直接 categories[0] 越界。
        guard !categories.isEmpty else {
            showEmptyState()
            return
        }
        emptyLabel.isHidden = true
        if typeCollectionView != nil {
            return
        }
        typeCollectionView = UICollectionView(frame: .zero, collectionViewLayout: BLSettingLineCollectionViewCell.makeLayout())
        typeCollectionView.register(BLSettingLineCollectionViewCell.self)
        view.addSubview(typeCollectionView)
        typeCollectionView.snp.makeConstraints { make in
            make.leading.bottom.equalToSuperview()
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.width.equalTo(sidebarWidth)
        }
        typeCollectionView.dataSource = self
        typeCollectionView.delegate = self

        view.addSubview(contentView)
        contentView.snp.makeConstraints { make in
            make.bottom.right.equalToSuperview()
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.left.equalTo(typeCollectionView.snp.right)
        }
        typeCollectionView.selectItem(at: IndexPath(item: 0, section: 0), animated: false, scrollPosition: .top)
        collectionView(typeCollectionView, didSelectItemAt: IndexPath(item: 0, section: 0))
    }

    private func showEmptyState() {
        if emptyLabel.superview == nil {
            view.addSubview(emptyLabel)
            emptyLabel.makeConstraintsCenteredWithinSafeArea(of: view)
        }
        emptyLabel.text = emptyStateText
        emptyLabel.isHidden = false
    }

    func reloadData() {
        forwardReloadToContentViewController()
    }
}

extension CategoryViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return categories.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeue(BLSettingLineCollectionViewCell.self, for: indexPath)
        cell.titleLabel.text = categories[indexPath.item].title
        return cell
    }
}

extension CategoryViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard categories.indices.contains(indexPath.item) else { return }
        setViewController(vc: categories[indexPath.item].contentVC)
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        if Settings.sideMenuAutoSelectChange == false {
            return
        }
        guard let nextFocusedIndexPath = context.nextFocusedIndexPath,
              categories.indices.contains(nextFocusedIndexPath.item)
        else {
            return
        }
        let categoryModel = categories[nextFocusedIndexPath.item]
        if categoryModel.autoSelect == false {
            // 不自动选中
            return
        }
        collectionView.selectItem(at: nextFocusedIndexPath, animated: true, scrollPosition: .centeredHorizontally)
        setViewController(vc: categoryModel.contentVC)
    }
}
