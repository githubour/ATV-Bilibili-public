//
//  VideoDetailViewController+PageRanges.swift
//  ATV-Bilibili
//
//  从 VideoDetailViewController.swift 按 iPad 分发版的拆分蓝图迁出（审核行动项 #9），零行为变化。
//

import AVKit
import Combine
import Foundation
import UIKit

import Alamofire
import Kingfisher
import SnapKit

// 分 P 大于 20 时的分段选择条

extension VideoDetailViewController {
    static let pageSectionTitleIdentifier = "pageSectionTitleLabel"

    func setupPageRangeCollectionView() {
        guard let titleLabel = pageView.subviews
            .compactMap({ $0 as? UILabel })
            .first(where: { $0.accessibilityIdentifier == Self.pageSectionTitleIdentifier })
        else {
            Logger.warn("找不到「视频选集」标题，跳过分段时间轴布局")
            return
        }

        pageView.addSubview(pageRangeCollectionView)

        let storyboardTopConstraints = pageView.constraints.filter { constraint in
            (constraint.firstItem as? UICollectionView) === pageCollectionView && constraint.firstAttribute == .top
        }
        storyboardTopConstraints.forEach { $0.isActive = false }

        let storyboardHeightConstraints = (pageView.constraints + pageCollectionView.constraints).filter { constraint in
            (constraint.firstItem as? UICollectionView) === pageCollectionView && constraint.firstAttribute == .height
        }
        storyboardHeightConstraints.forEach { $0.isActive = false }

        pageRangeCollectionView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalTo(titleLabel.snp.bottom).offset(30)
            make.height.equalTo(90)
        }
        pageCollectionView.snp.makeConstraints { make in
            pageCollectionViewTopToTitleConstraint = make.top.equalTo(titleLabel.snp.bottom).offset(30).constraint
            pageCollectionViewTopToRangeConstraint = make.top.equalTo(pageRangeCollectionView.snp.bottom).offset(30).constraint
            make.height.equalTo(150)
        }
        pageCollectionViewTopToRangeConstraint?.deactivate()
    }

    func updatePageRanges() {
        guard pages.count >= pageRangeSize else {
            pageRanges = []
            setPageRangeCollectionViewHidden(true)
            return
        }

        pageRanges = stride(from: 0, to: pages.count, by: pageRangeSize).map { startIndex in
            PageRange(startIndex: startIndex, endIndex: min(startIndex + pageRangeSize, pages.count) - 1)
        }
        setPageRangeCollectionViewHidden(false)
    }

    func setPageRangeCollectionViewHidden(_ isHidden: Bool) {
        pageRangeCollectionView.isHidden = isHidden
        if isHidden {
            pageCollectionViewTopToRangeConstraint?.deactivate()
            pageCollectionViewTopToTitleConstraint?.activate()
        } else {
            pageCollectionViewTopToTitleConstraint?.deactivate()
            pageCollectionViewTopToRangeConstraint?.activate()
        }
    }

    struct PageRange {
        let startIndex: Int
        let endIndex: Int

        var title: String {
            "\(startIndex + 1) - \(endIndex + 1)"
        }
    }
}
