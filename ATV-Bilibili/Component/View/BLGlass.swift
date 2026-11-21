//
//  BLGlass.swift
//  ATV-Bilibili
//
//  通用玻璃底材：tvOS 26 真 Liquid Glass，老系统回退半透明深薄材质
//
//  2026-11-01 用户反馈「胶囊的玻璃不够液态、边缘和中间一样，更像毛玻璃」：
//  - 档位从 `.regular` 换成 `.clear`。`.regular` 自带一层偏实的磨砂底，把系统管线的
//    折射/边缘弯折盖住了，看着就是一块均匀的毛玻璃；`.clear` 才只做折射与高光。
//  - 胶囊补一层纯高光的 `BLGlassRimView`（上缘 sheen + 上亮下暗的 1pt rim）。
//    注意：**不能**用黑描边/黑色内阴影去「压边缘」——那是伪玻璃，用户明确反感。
//

import UIKit

/// 玻璃档位。不能直接把 `UIGlassEffect.Style` 写进签名：它只有 tvOS 26 才有，
/// 函数签名在 tvOS 18 编译时同样要解析得到。
enum BLGlassStyle {
    /// 只做折射与高光，更透 —— 胶囊、按钮这类小面积。
    case clear
    /// 自带一层偏实的漫射底，保文字对比度 —— 面板、侧栏这类大面积。
    case regular
}

@MainActor
enum BLGlass {
    /// - Parameters:
    ///   - style: 小面积胶囊用 `.clear`（更透、更像液态玻璃），大面积面板用 `.regular`。
    ///   - interactive: 聚焦/按压时由系统叠一层高光响应。
    static func effect(_ style: BLGlassStyle = .clear, interactive: Bool = false) -> UIVisualEffect {
        if #available(tvOS 26.0, *) {
            let effect = UIGlassEffect(style: style == .clear ? .clear : .regular)
            effect.isInteractive = interactive
            return effect
        }
        // tvOS 没有 iOS 的 system*Material 系列；regular 随外观自适应，深色下即深色半透明模糊
        return UIBlurEffect(style: .regular)
    }
}

/// 玻璃边缘的高光层（纯高光，不含任何黑色描边）。
///
/// Liquid Glass 在边缘的两件事系统只做了一半：折射（`UIGlassEffect` 自带）与**镜面高光**。
/// 胶囊又薄又小，高光不明显就会退化成「均匀磨砂」。这个视图补两层：
/// 1) 上缘 sheen：白色渐变，只覆盖上 45%，模拟环境光打在玻璃上表面；
/// 2) rim：1pt 描边，上亮下暗（上 0.55 / 下 0.10），勾出玻璃厚度。
/// 都是叠加光，不改变中心透明度 —— 中心仍然透，边缘才有「液态」的边界。
final class BLGlassRimView: UIView {
    /// 0 = 胶囊（按高度取一半），面板传固定半径。
    var cornerRadius: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    private let sheen = CAGradientLayer()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        sheen.colors = [
            UIColor.white.withAlphaComponent(0.20).cgColor,
            UIColor.white.withAlphaComponent(0.05).cgColor,
            UIColor.white.withAlphaComponent(0).cgColor,
        ]
        sheen.locations = [0, 0.28, 0.55]
        layer.addSublayer(sheen)

        rim.colors = [
            UIColor.white.withAlphaComponent(0.55).cgColor,
            UIColor.white.withAlphaComponent(0.18).cgColor,
            UIColor.white.withAlphaComponent(0.10).cgColor,
        ]
        rim.locations = [0, 0.5, 1]
        rim.startPoint = CGPoint(x: 0.5, y: 0)
        rim.endPoint = CGPoint(x: 0.5, y: 1)
        rim.mask = rimMask
        layer.addSublayer(rim)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let radius = cornerRadius > 0 ? cornerRadius : bounds.height / 2
        let shapePath = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                     cornerRadius: max(0, radius - 0.5))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheen.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.55)
        rim.frame = bounds
        rimMask.frame = bounds
        rimMask.path = shapePath.cgPath
        rimMask.fillColor = UIColor.clear.cgColor
        rimMask.strokeColor = UIColor.white.cgColor
        rimMask.lineWidth = 1
        CATransaction.commit()
    }
}
