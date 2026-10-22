//
//  DanmakuTextCell.swift
//  DanmakuKit_Example
//
//  Created by Q YiZhong on 2020/8/29.
//  Copyright © 2020 CocoaPods. All rights reserved.
//

import UIKit

class DanmakuTextCell: DanmakuCell {
    required init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 缓存键 = 文本 + 字体 + 颜色 + 描边/透明度 + 位图尺寸。
    /// `displaying` 画的东西完全由这几项决定，键相同就一定同图，可以直接复用位图。
    override var displayCacheKey: String? {
        guard let model = model as? DanmakuTextCellModel else { return nil }
        let size = model.size
        return [
            "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))",
            model.font.fontName,
            "\(model.font.pointSize)",
            Self.colorKey(model.color),
            "\(Settings.danmakuAlpha.rawValue)",
            "\(Settings.danmakuStrokeWidth.rawValue)",
            "\(Settings.danmakuStrokeAlpha.rawValue)",
            model.text,
        ].joined(separator: "|")
    }

    private static func colorKey(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return String(describing: color) }
        return "\(Int(r * 255))-\(Int(g * 255))-\(Int(b * 255))-\(Int(a * 255))"
    }

    override func displaying(_ context: CGContext, _ size: CGSize, _ isCancelled: Bool) {
        guard let model = model as? DanmakuTextCellModel else { return }
        let text = NSString(string: model.text)
        context.setAlpha(CGFloat(Settings.danmakuAlpha.rawValue))
        context.setLineWidth(CGFloat(Settings.danmakuStrokeWidth.rawValue))
        context.setLineJoin(.round)
        context.saveGState()
        context.setTextDrawingMode(.stroke)

        let strokeColor = UIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: CGFloat(Settings.danmakuStrokeAlpha.rawValue))
        let attributes: [NSAttributedString.Key: Any] = [.font: model.font, .foregroundColor: strokeColor]
        context.setStrokeColor(strokeColor.cgColor)
        text.draw(at: .zero, withAttributes: attributes)
        context.restoreGState()

        let attributes1: [NSAttributedString.Key: Any] = [.font: model.font, .foregroundColor: model.color]
        context.setTextDrawingMode(.fill)
        context.setStrokeColor(UIColor.white.cgColor)
        text.draw(at: .zero, withAttributes: attributes1)
    }
}
