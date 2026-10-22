//
//  DanmakuAsyncLayer.swift
//  DanmakuKit
//
//  Created by Q YiZhong on 2020/8/16.
//

import UIKit

class Sentinel {
    private var value: Int32 = 0

    public func getValue() -> Int32 {
        return value
    }

    public func increase() {
        value += 1
    }
}

var pool: DanmakuQueuePool!

/// 弹幕位图缓存。
///
/// 原实现里每来一条弹幕（含 cell 复用后换 model 的情况）都要走一次 `UIGraphicsImageRenderer`
/// 把文字重新画成位图，高密度稿件下这是主要的 CPU 开销。同一段文字 + 同一套样式画出来的位图完全一样，
/// 按「内容 + 样式 + 尺寸」缓存 `CGImage` 即可，命中时只付一次字典查找。
///
/// 容量做了双重限制：条目数与总字节数。长弹幕的位图可以到几百 KB，只按条数限容在极端情况下会占上百 MB
/// （tvOS 内存吃紧），所以用 `bytesPerRow * height` 记账，超预算就从最旧的开始淘汰。
final class DanmakuBitmapCache {
    static let shared = DanmakuBitmapCache(maxEntries: 200, maxBytes: 8 * 1024 * 1024)

    private let maxEntries: Int
    private let maxBytes: Int
    private var storage = [String: CGImage]()
    /// 触达顺序：命中/写入移到队尾，淘汰从队首取
    private var order = [String]()
    private var bytes = 0
    private let lock = NSLock()

    init(maxEntries: Int, maxBytes: Int) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }

    func image(forKey key: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let image = storage[key] else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return image
    }

    func store(_ image: CGImage, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let old = storage[key] {
            bytes -= old.bytesPerRow * old.height
        } else {
            order.append(key)
        }
        storage[key] = image
        bytes += image.bytesPerRow * image.height
        // storage.count > 1 的下限保证「单张就超预算」时不会把刚存进去的那张也淘汰掉
        while storage.count > 1, order.count > maxEntries || bytes > maxBytes, let oldest = order.first {
            order.removeFirst()
            if let evicted = storage.removeValue(forKey: oldest) {
                bytes -= evicted.bytesPerRow * evicted.height
            }
        }
    }
}

class DanmakuAsyncLayer: CALayer {
    /// When true, it is drawn asynchronously and is ture by default.
    public var displayAsync = true

    /// 位图缓存键，由 cell 按自身绘制参数生成；nil 表示不缓存（本层的默认行为）。
    /// 键必须包含一切影响像素结果的参数——文本、字号、颜色、描边、透明度、尺寸，
    /// 而缩放（contentsScale）与不透明（isOpaque）由本层在键尾部补齐。
    public var cacheKey: String?

    public var willDisplay: ((_ layer: DanmakuAsyncLayer) -> Void)?

    public var displaying: ((_ context: CGContext, _ size: CGSize, _ isCancelled: () -> Bool) -> Void)?

    public var didDisplay: ((_ layer: DanmakuAsyncLayer, _ finished: Bool) -> Void)?

    private let sentinel = Sentinel()

    override init() {
        super.init()
        contentsScale = UIScreen.main.scale
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        sentinel.increase()
    }

    override func setNeedsDisplay() {
        // 1. Cancel the last drawing
        sentinel.increase()
        // 2. call super
        super.setNeedsDisplay()
    }

    override func display() {
        display(async: displayAsync)
    }

    private func display(async: Bool) {
        guard displaying != nil else {
            willDisplay?(self)
            contents = nil
            didDisplay?(self, true)
            return
        }

        // 键里补上缩放。isOpaque 时位图还会被 backgroundColor 影响，而它不在缓存键里 ——
        // 这种层（本项目用不到）直接不缓存，宁可多画一次也不复用错图。
        let cacheKey = isOpaque ? nil : self.cacheKey.map { "\($0)|scale=\(contentsScale)" }

        if async {
            willDisplay?(self)
            let value = sentinel.getValue()
            let isCancelled = { () -> Bool in
                return value != self.sentinel.getValue()
            }
            let size = bounds.size
            let scale = contentsScale
            let opaque = isOpaque
            let backgroundColor = (opaque && self.backgroundColor != nil) ? self.backgroundColor : nil
            pool.queue.async {
                guard !isCancelled() else { return }
                if let cacheKey, let cached = DanmakuBitmapCache.shared.image(forKey: cacheKey) {
                    DispatchQueue.main.async {
                        if isCancelled() {
                            self.didDisplay?(self, false)
                        } else {
                            self.contents = cached
                            self.didDisplay?(self, true)
                        }
                    }
                    return
                }
                let format = UIGraphicsImageRendererFormat.preferred()
                format.opaque = opaque
                format.scale = scale
                let render = UIGraphicsImageRenderer(size: size)
                let image = render.image { rendererContext in
                    if opaque {
                        rendererContext.cgContext.saveGState()
                        if backgroundColor == nil || (backgroundColor?.alpha ?? 0) < 1 {
                            UIColor.white.setFill()
                            rendererContext.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
                        }
                        if let backgroundColor = backgroundColor {
                            UIColor(cgColor: backgroundColor).setFill()
                            rendererContext.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
                        }
                        rendererContext.cgContext.restoreGState()
                    }
                    self.displaying?(rendererContext.cgContext, size, isCancelled)
                }
                if let cacheKey, let rendered = image.cgImage {
                    DanmakuBitmapCache.shared.store(rendered, forKey: cacheKey)
                }
                if isCancelled() {
                    DispatchQueue.main.async {
                        self.didDisplay?(self, false)
                    }
                    return
                }
                DispatchQueue.main.async {
                    if isCancelled() {
                        self.didDisplay?(self, false)
                    } else {
                        self.contents = image.cgImage
                        self.didDisplay?(self, true)
                    }
                }
            }

        } else {
            sentinel.increase()
            willDisplay?(self)
            if let cacheKey, let cached = DanmakuBitmapCache.shared.image(forKey: cacheKey) {
                contents = cached
                didDisplay?(self, true)
                return
            }
            let format = UIGraphicsImageRendererFormat.preferred()
            format.opaque = isOpaque
            format.scale = contentsScale
            let render = UIGraphicsImageRenderer(size: bounds.size)
            let image = render.image { rendererContext in
                displaying?(rendererContext.cgContext, bounds.size, { () -> Bool in return false })
            }
            contents = image.cgImage
            if let cacheKey, let rendered = image.cgImage {
                DanmakuBitmapCache.shared.store(rendered, forKey: cacheKey)
            }
            didDisplay?(self, true)
        }
    }
}
