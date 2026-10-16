//
//  BLCardView.swift
//  ATV-Bilibili
//

import TVUIKit
import UIKit

class BLCardView: TVCardView {
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        applyLiquidGlassCornerRadius()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cardBackgroundColor = UIColor(named: "bgColor")
        applyLiquidGlassCornerRadius()
    }

    /// 评论卡片会随内容长短改变高度, 每次布局都按当前高度重算统一圆角
    private func applyLiquidGlassCornerRadius() {
        let radius = BLCardCornerRadius.value(forHeight: bounds.height)
        contentView.layer.cornerRadius = radius
        contentView.layer.cornerCurve = .continuous
        // 卡片底色由 TVUIKit 内部私有视图绘制, 沿用既有的层级定位同步圆角
        backgroundDecorationView?.layer.cornerRadius = radius
    }

    private var backgroundDecorationView: UIView? {
        subviews.first?.subviews.first?.subviews.last?.subviews.first?.subviews.first
    }
}
