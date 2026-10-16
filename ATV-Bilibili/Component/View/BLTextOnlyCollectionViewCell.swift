//
//  BLTextOnlyCollectionViewCell.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/10/24.
//

import Foundation
import UIKit

class BLTextOnlyCollectionViewCell: BLMotionCollectionViewCell {
    private let effectView = BLCapsuleEffectView(effect: UIBlurEffect(style: .dark))
    private let selectedWhiteView = UIView()
    let titleLabel = UILabel()

    override func setup() {
        super.setup()
        scaleFactor = 1.15
        contentView.addSubview(effectView)
        effectView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        effectView.contentView.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.centerX.centerY.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(28)
            make.top.bottom.lessThanOrEqualToSuperview().inset(8)
        }
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.font = UIFont.systemFont(ofSize: 26, weight: .medium)
        // tvOS 26+ Liquid Glass 风格: 胶囊形 (圆角由 BLCapsuleEffectView 按高度自适应)
        effectView.clipsToBounds = true
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        selectedWhiteView.isHidden = !isFocused
    }
}
