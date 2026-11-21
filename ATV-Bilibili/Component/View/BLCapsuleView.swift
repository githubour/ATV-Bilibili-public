//
//  BLCapsuleView.swift
//  ATV-Bilibili
//
//  Liquid Glass 胶囊形容器的共享实现。
//
//  圆角必须在**容器自身的 layoutSubviews** 里按高度算：视图自身的布局回调一定在 frame
//  确定之后触发，而外层 cell 首次布局时子视图约束可能还没生效（bounds 为 0），
//  在那里算出的圆角会一直是 0 且不再刷新 —— 这正是排行榜侧栏曾经"还是方的"的原因。
//

import UIKit

enum BLCapsuleShape {
    /// 按当前高度取全圆角（胶囊形），并启用连续曲率
    static func apply(to view: UIView) {
        view.layer.cornerRadius = view.bounds.height / 2
        view.layer.cornerCurve = .continuous
    }
}

/// 胶囊形模糊容器：侧栏菜单项、纯文字卡片
///
/// 边缘补一层纯高光（`BLGlassRimView`）：系统玻璃在这么薄的胶囊上高光不明显，
/// 不补就退化成均匀毛玻璃（用户 2026-11-01 反馈「边缘和中间一样」）。
/// rim 加在 `contentView` 最底层，调用方后续加进来的文字仍然压在它上面。
final class BLCapsuleEffectView: UIVisualEffectView {
    private let rim = BLGlassRimView()

    override init(effect: UIVisualEffect?) {
        super.init(effect: effect)
        installRim()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func installRim() {
        rim.frame = contentView.bounds
        rim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.insertSubview(rim, at: 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        BLCapsuleShape.apply(to: self)
        rim.frame = contentView.bounds
    }
}

/// 胶囊形实色容器：导航栏自定义磁贴
final class BLCapsuleBackgroundView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        BLCapsuleShape.apply(to: self)
    }
}
