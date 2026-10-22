//
//  DanmakuCell.swift
//  DanmakuKit
//
//  Created by Q YiZhong on 2020/8/16.
//

import UIKit

open class DanmakuCell: UIView {
    public var model: DanmakuCellModel? {
        didSet {
            // 位图缓存键由 cell 按当前绘制参数生成，model 变了就跟着换（弹幕池复用正是走这条路径）
            (layer as? DanmakuAsyncLayer)?.cacheKey = displayCacheKey
        }
    }

    /// 位图缓存键，nil = 不缓存。子类按自身绘制参数（文本/字号/颜色/描边/…）覆盖。
    var displayCacheKey: String? { nil }

    public internal(set) var animationTime: TimeInterval = 0

    var animationBeginTime: TimeInterval = 0

    override public class var layerClass: AnyClass {
        return DanmakuAsyncLayer.self
    }

    override public required init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    open func willDisplay() {}

    open func displaying(_ context: CGContext, _ size: CGSize, _ isCancelled: Bool) {}

    open func didDisplay(_ finished: Bool) {}

    public var displayAsync = true {
        didSet {
            guard let layer = layer as? DanmakuAsyncLayer else { return }
            layer.displayAsync = oldValue
        }
    }
}

extension DanmakuCell {
    var realFrame: CGRect {
        if layer.presentation() != nil {
            return layer.presentation()!.frame
        } else {
            return frame
        }
    }

    func setupLayer() {
        guard let layer = layer as? DanmakuAsyncLayer else { return }

        layer.willDisplay = { [weak self] layer in
            guard let strongSelf = self else { return }
            strongSelf.willDisplay()
        }

        layer.displaying = { [weak self] context, size, isCancelled in
            guard let strongSelf = self else { return }
            strongSelf.displaying(context, size, isCancelled())
        }

        layer.didDisplay = { [weak self] layer, finished in
            guard let strongSelf = self else { return }
            strongSelf.didDisplay(finished)
        }
    }
}
