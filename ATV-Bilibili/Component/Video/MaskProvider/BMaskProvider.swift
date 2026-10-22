//
//  BMaskProvider.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/11/9.
//

import Alamofire
import AVFoundation
import Foundation
import Gzip
import PocketSVG
import UIKit

class BMaskProvider: MaskProvider {
    let info: PlayerInfo.MaskInfo
    let videoSize: CGSize
    private let maskFramesLock = NSLock()
    private lazy var shapeLayer = CAShapeLayer()

    private var lastTime: TimeInterval = 0
    /// 下载 + 建段索引的任务（不再顺带把整条流解成帧）
    private var indexTask: Task<Void, Never>?

    // MARK: 按需解析状态

    /// 每段原始（gunzip 前）载荷。整条遮罩流只保留压缩态，
    /// 内存占用比「全部解成 CGPath 帧」小得多
    private var segmentPayloads = [Data]()
    /// 段起始时间（毫秒，升序）。它非空即代表索引就绪——置位放在几何信息写入之后，
    /// 且读侧一律先拿锁再读，保证「写在前、读在后」
    private var segmentTimes = [UInt32]()
    /// 已解析的段（键 = 段下标）与其触达顺序
    private var parsedSegments = [Int: [MaskFrame]]()
    private var parsedOrder = LRUOrder<Int>()
    /// 正在后台解析的段，避免同一段重复入队
    private var parsingSegments = Set<Int>()
    /// 同时保留的已解析段数：播放位置附近几段够用，再多就纯粹是占内存
    private let maxParsedSegments = 3

    // MARK: 几何信息（索引建成时算一次，之后解析每段复用）

    private var screenSize = CGSize.zero
    private var fittedSize = CGSize.zero
    private var maskOffset = CGPoint.zero
    private var paddingPaths = [UIBezierPath]()

    init(info: PlayerInfo.MaskInfo, videoSize: CGSize) {
        self.info = info
        self.videoSize = videoSize
        indexTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            try? await self.download()
        }
    }

    deinit {
        indexTask?.cancel()
    }

    /// 只做「下载 → 建段索引」，不再把整条遮罩流一次性解成帧。
    /// 30 分钟稿件约 1800 帧，起播瞬间全量 gunzip + base64 + SVG 解析会在播放刚开始那几秒
    /// 堆出明显的 CPU/内存尖峰，而这些帧绝大多数要等播放走到才用得上。
    private func download() async throws {
        guard let url = info.mask_url?.addSchemeIfNeed() else { return }
        let data = try await AF.request(url).serializingData().value
        guard !Task.isCancelled else { return }
        let segments = buildSegmentIndex(from: data)
        guard !Task.isCancelled, !segments.isEmpty else { return }

        let size = await UIScreen.main.bounds.size
        let fitted = CGSize.aspectFit(aspectRatio: videoSize, boundingSize: size)
        let x = (size.width - fitted.width) / 2.0
        let y = (size.height - fitted.height) / 2.0

        var padding = [UIBezierPath]()
        if x > 0 {
            padding.append(UIBezierPath(rect: CGRect(x: 0, y: 0, width: x, height: size.height)))
            padding.append(UIBezierPath(rect: CGRect(x: size.width - x, y: 0, width: x, height: size.height)))
        } else if y > 0 {
            padding.append(UIBezierPath(rect: CGRect(x: 0, y: 0, width: size.width, height: y)))
            padding.append(UIBezierPath(rect: CGRect(x: 0, y: size.height - y, width: size.width, height: y)))
        }

        maskFramesLock.lock()
        segmentPayloads = segments.map(\.payload)
        screenSize = size
        fittedSize = fitted
        maskOffset = CGPoint(x: x, y: y)
        paddingPaths = padding
        segmentTimes = segments.map(\.time)
        maskFramesLock.unlock()
    }

    /// 解析「表头 + 段表」得到每段的原始字节区间：只切载荷，不解压也不解 SVG。
    /// 段表每项 16 字节，只有 start/end 都为 0 的才是真段（与原实现一致）。
    private func buildSegmentIndex(from data: Data) -> [(time: UInt32, payload: Data)] {
        let header = WebMaskInfoHeader.decode(data: data.prefix(16))
        let segments = header.segments
        var buffer = data
        var metas = [SegmentData]()
        for _ in 0..<segments {
            // 段表逐项消耗 16 字节，尾部不足即停止（畸形数据防切片越界）
            guard buffer.count >= 16 else { break }
            buffer = buffer.subdata(in: 16..<buffer.count)
            guard buffer.count >= 16 else { break }
            let start = buffer[0..<4].withUnsafeBytes({ $0.load(as: UInt32.self) })
            let end = buffer[8..<12].withUnsafeBytes({ $0.load(as: UInt32.self) })
            if start == 0 && end == 0 {
                let time = buffer[4..<8].withUnsafeBytes({ $0.load(as: UInt32.self) }).bigEndian
                let offset = buffer[12..<16].withUnsafeBytes({ $0.load(as: UInt32.self) }).bigEndian
                metas.append(SegmentData(time: time, offset: offset))
            }
        }
        guard buffer.count >= 16 else { return [] }
        buffer = buffer.subdata(in: 16..<buffer.count)

        var result = [(time: UInt32, payload: Data)]()
        var cursor = 0
        let num = metas.count
        for i in 0..<num {
            let seg = metas[i]
            let length: UInt32
            if i < num - 1 {
                // offset 倒序或差值为负都是脏数据，UInt32 相减会下溢 trap，跳过该段
                guard metas[i + 1].offset >= seg.offset else { continue }
                length = metas[i + 1].offset - seg.offset
            } else {
                guard seg.offset <= UInt32(data.count) else { continue }
                length = UInt32(data.count) - seg.offset
            }
            // 声明的段长超过剩余载荷时跳过，防止切片越界
            guard Int(length) <= buffer.count - cursor else { continue }
            result.append((time: seg.time, payload: buffer.subdata(in: cursor..<(cursor + Int(length)))))
            cursor += Int(length)
        }
        return result.sorted { $0.time < $1.time }
    }

    // MARK: 按需解析

    /// 解析单段：gunzip → 逐帧 base64 → SVG path。
    /// 只在播放位置落到该段时才做，且全程在后台；播放器的时间观察回调（主线程、按帧触发）里不做这件事。
    private func parseSegment(at index: Int) -> [MaskFrame] {
        guard index >= 0, index < segmentPayloads.count else { return [] }
        guard var buffer = try? segmentPayloads[index].gunzipped() else {
            // 单帧解压失败只影响该段的遮罩，跳过即可，不应让整个解析崩掉
            Logger.warn("[mask] gunzip 失败，跳过该 segment")
            return []
        }
        var frames = [MaskFrame]()
        autoreleasepool {
            // 一帧最少 12 字节（4 offset + 4 保留 + 4 time），尾部不足整帧即停止
            while buffer.count >= 12 {
                let offset = buffer[0..<4].withUnsafeBytes({ $0.load(as: UInt32.self) }).bigEndian
                let time = buffer[8..<12].withUnsafeBytes({ $0.load(as: UInt32.self) }).bigEndian
                // base64 载荷切片前校验；guard 在 while 体内（不能放进 defer）
                guard 12 + Int(offset) <= buffer.count else { break }

                defer {
                    buffer = buffer.subdata(in: 12 + Int(offset)..<buffer.count)
                }
                let b64Data = buffer[12..<12 + Int(offset)]
                guard var b64String = String(data: b64Data, encoding: .utf8) else { continue }
                b64String = b64String.replacingOccurrences(of: "\n", with: "")
                b64String = String(b64String.components(separatedBy: ";base64,").last ?? b64String)
                guard let newb64Data = Data(base64Encoded: b64String),
                      let decodedString = String(data: newb64Data, encoding: .utf8) else { continue }

                let paths = SVGBezierPath.paths(fromSVGString: decodedString)

                let mergedPath = paths.first ?? UIBezierPath(rect: CGRect(x: 0, y: 0, width: screenSize.width, height: screenSize.height))
                for path in paths.dropFirst() {
                    mergedPath.append(path)
                }

                let coordTransform = CGAffineTransform(translationX: maskOffset.x, y: maskOffset.y).scaledBy(x: fittedSize.width / mergedPath.bounds.width, y: fittedSize.height / mergedPath.bounds.height)
                let finalTransform = coordTransform.scaledBy(x: 1, y: -1).translatedBy(x: 0, y: 0 - mergedPath.bounds.height - mergedPath.bounds.origin.y)
                mergedPath.apply(finalTransform)
                paddingPaths.forEach { mergedPath.append($0) }
                let reversedPath = mergedPath.reversing()
                let cgPath = reversedPath.cgPath.copy() ?? reversedPath.cgPath
                frames.append(MaskFrame(time: time, path: cgPath))
            }
        }
        SVGBezierPath.resetCache()
        // 段内帧理论上就按时间递增，兜一次底，保证二分查找的前提成立
        return frames.sorted { $0.time < $1.time }
    }

    /// 预读播放位置附近的段：当前段 + 下一段，跨段时不用干等解析
    private func prefetchSegments(around index: Int) {
        prefetchSegment(index)
        prefetchSegment(index + 1)
    }

    private func prefetchSegment(_ index: Int) {
        maskFramesLock.lock()
        let needParse = index >= 0
            && index < segmentPayloads.count
            && parsedSegments[index] == nil
            && parsingSegments.insert(index).inserted
        maskFramesLock.unlock()
        guard needParse else { return }
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let frames = self.parseSegment(at: index)
            self.storeSegment(frames, at: index)
        }
    }

    private func storeSegment(_ frames: [MaskFrame], at index: Int) {
        maskFramesLock.lock()
        parsedSegments[index] = frames
        parsedOrder.touch(index)
        parsingSegments.remove(index)
        // 只保留播放位置附近几段，超出的从最旧的开始丢 —— 全量驻留正是起播尖峰的来源
        while parsedSegments.count > maxParsedSegments, let oldest = parsedOrder.popOldest() {
            parsedSegments.removeValue(forKey: oldest)
        }
        maskFramesLock.unlock()
    }

    // MARK: 查询

    /// 取该时刻生效的遮罩路径。
    /// 调用方是播放器的周期时间观察回调（主线程、按帧触发），所以这里必须保持廉价：
    /// 已解析的段走「加锁 → 二分 → 字典查」，未解析的段立刻返回 nil 并把解析丢到后台。
    private func framePath(for time: UInt32) -> CGPath? {
        maskFramesLock.lock()
        let ready = !segmentTimes.isEmpty
        let index = ready ? segmentIndex(containing: time) : -1
        maskFramesLock.unlock()
        guard index >= 0 else { return nil }

        prefetchSegments(around: index)

        if let path = latestPath(before: time, inSegmentAt: index) { return path }
        // 段边界上：本段的帧都还没到（首个帧晚于查询时刻），往回退一段取。
        // 原实现是在全局帧表里二分，等价行为。
        return index > 0 ? latestPath(before: time, inSegmentAt: index - 1) : nil
    }

    private func latestPath(before time: UInt32, inSegmentAt index: Int) -> CGPath? {
        maskFramesLock.lock()
        let frames = parsedSegments[index]
        if frames != nil {
            parsedOrder.touch(index)
        }
        maskFramesLock.unlock()
        guard let frames, !frames.isEmpty else { return nil }

        var low = 0
        var high = frames.count - 1
        var found = -1
        while low <= high {
            let mid = low + (high - low) / 2
            if frames[mid].time <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        // 过期帧不显示：从中间起播时解析还在追进度，只有 1 秒内的帧才算数
        guard found >= 0, time - frames[found].time < 1000 else { return nil }
        return frames[found].path
    }

    /// 最后一个 `time <= 查询值` 的段下标；段表按时间升序，找不到返回 -1
    private func segmentIndex(containing time: UInt32) -> Int {
        var low = 0
        var high = segmentTimes.count - 1
        var found = -1
        while low <= high {
            let mid = low + (high - low) / 2
            if segmentTimes[mid] <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    func getMask(for time: CMTime, frame: CGRect, onGet: (CALayer) -> Void) {
        let time = time.seconds + 0.1
        guard time != lastTime else { return }
        lastTime = time
        if time < 0 { return }
        guard let path = framePath(for: UInt32(time * 1000)) else { return }
        shapeLayer.path = path
        shapeLayer.fillColor = UIColor.white.cgColor
        shapeLayer.strokeColor = UIColor.white.cgColor
        shapeLayer.backgroundColor = UIColor.clear.cgColor
        shapeLayer.frame = frame
        onGet(shapeLayer)
    }

    func needVideoOutput() -> Bool {
        return false
    }

    func setVideoOutout(ouput: AVPlayerItemVideoOutput) {}
    func preferFPS() -> Int {
        return info.fps
    }
}

extension BMaskProvider {
    struct MaskFrame {
        let time: UInt32
        let path: CGPath
    }

    struct SegmentData {
        let time: UInt32
        let offset: UInt32
    }

    struct WebMaskInfoHeader {
        var tag: UInt8
        var tag1: UInt8
        var tag2: UInt8
        var tag3: UInt8

        var version: UInt32
        var checkcode: UInt8
        var segments: UInt32

        static func decode(data: Data) -> WebMaskInfoHeader {
            var header = (data as NSData).bytes.bindMemory(to: WebMaskInfoHeader.self, capacity: data.count).pointee
            header.version = header.version.bigEndian
            header.checkcode = header.checkcode.bigEndian
            header.segments = header.segments.bigEndian
            return header
        }
    }
}

extension CGSize {
    static func aspectFit(aspectRatio: CGSize, boundingSize: CGSize) -> CGSize {
        var boundingSize = boundingSize
        let mW = boundingSize.width / aspectRatio.width
        let mH = boundingSize.height / aspectRatio.height

        if mH < mW {
            boundingSize.width = boundingSize.height / aspectRatio.height * aspectRatio.width
        } else if mW < mH {
            boundingSize.height = boundingSize.width / aspectRatio.width * aspectRatio.height
        }

        return boundingSize
    }
}
