//
//  BLCardCornerRadius.swift
//  ATV-Bilibili
//
//  Liquid Glass 内容卡片的统一圆角。
//
//  纯文字/胶囊型条目（侧栏菜单、导航栏磁贴、选集文字卡）用整条胶囊（高度的一半）；
//  带封面或头像的内容卡片（评论、相关推荐、播放器分集卡片）比文字条"胖"，
//  整条胶囊会把画面两端切得太狠，因此按高度取比例并在合理区间内收敛。
//

import UIKit

enum BLCardCornerRadius {
    /// 内容卡片圆角 = 高度的 30%，下限 24pt、上限 60pt
    static func value(forHeight height: CGFloat) -> CGFloat {
        guard height > 0 else { return 24 }
        return min(max(height * 0.3, 24), 60)
    }
}

/// 封面视图：在自身布局回调里按高度设定圆角。
/// 与胶囊视图同理 —— 视图自身的 layoutSubviews 一定在 frame 确定之后触发，
/// 不依赖 cell 的布局时序（cell 首次布局时子视图约束可能尚未生效）。
final class BLRoundedImageView: UIImageView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = BLCardCornerRadius.value(forHeight: bounds.height)
        layer.cornerCurve = .continuous
        clipsToBounds = true
    }
}
