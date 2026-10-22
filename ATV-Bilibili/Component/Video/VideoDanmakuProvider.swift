//
//  VideoDanmakuProvider.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/8/19.
//

import Alamofire
import Combine
import Foundation
import UIKit

struct Danmaku: Codable {
    var text: String
    var time: TimeInterval
    var mode: Int32 = 1
    var fontSize: Int32 = 25
    var color: UInt32 = 16_777_215
    var isUp: Bool = false
    var aiLevel: Int32 = 0

    init(dm: DanmakuElem) {
        text = dm.content
        time = TimeInterval(dm.progress / 1000)
        mode = dm.mode
        fontSize = dm.fontsize
        color = dm.color
        aiLevel = dm.weight
    }

    init(upDm dm: CommandDm) {
        text = dm.content
        time = TimeInterval(dm.progress / 1000)
        isUp = true
    }
}

/// 视频弹幕数据源。可变状态(cid/segmentDanmakus/inFlightSegments/upDanmakus 及游标)只在主线程读写：
/// 网络请求是 async 调用不占主线程，状态的变更全部收敛在 @MainActor 方法内，
/// 避免后台 Task 写、playerTimeChange 主线程读的竞态
class VideoDanmakuProvider: DanmakuProviderProtocol {
    private var cid: Int?
    private let enableDanmakuFilter: Bool
    private let enableDanmakuRemoveDup: Bool

    let observerPlayerTime: Bool = true
    let onSendTextModel = PassthroughSubject<DanmakuTextCellModel, Never>()

    private var upDanmakus = [Danmaku]()
    private static let segmentMinCap = 5
    private var segmentDanmakus = [Int: [Danmaku]](minimumCapacity: segmentMinCap)
    /// 哪些分段已在途（此前用 [Int: Any] 存 true 当 Set 用，绕经 Any 装箱 + isNil() 扩展）
    private var inFlightSegments = Set<Int>()
    /// 失败分段的退避时间与连续失败次数：弱网/5xx 时避免每秒重试同一段。
    private var segmentRetryAt = [Int: Date]()
    private var segmentFailureCount = [Int: Int]()

    private var lastTime: TimeInterval = 0
    private var lastSegmentIdx: Int = 0
    private var upDanmakuIdx: Int = 0
    private var danmakuIdx: Int = 0

    private let segmentDuration = 60 * 6
    private func getSegmentIdx(time: TimeInterval) -> Int { Int(time) / segmentDuration + 1 }

    init(enableDanmakuFilter: Bool, enableDanmakuRemoveDup: Bool) {
        self.enableDanmakuFilter = enableDanmakuFilter
        self.enableDanmakuRemoveDup = enableDanmakuRemoveDup
    }

    @MainActor
    func initVideo(cid id: Int, startPos: Int) async {
        cid = id
        upDanmakus.removeAll()
        segmentDanmakus.removeAll(keepingCapacity: true)
        inFlightSegments.removeAll()
        segmentRetryAt.removeAll()
        segmentFailureCount.removeAll()
        lastTime = 0
        lastSegmentIdx = 0
        upDanmakuIdx = 0
        danmakuIdx = 0

        async let view: () = fetchDanmakuView()
        let segmentIdx = getSegmentIdx(time: TimeInterval(startPos))
        inFlightSegments.insert(segmentIdx)
        async let list: () = fetchDanmakuList(getSegmentIdx(time: TimeInterval(startPos)))
        await view
        await list
    }

    @MainActor
    func fetchDanmakuView() async {
        guard let cid else { return }
        var reply: DmWebViewReply
        do {
            reply = try await WebRequest.requestDanmakuWebView(cid: cid)
        } catch let err {
            Logger.warn("[dm] cid:\(cid) requestDanmuWebView error: \(err)")
            return
        }

        var dms = reply.commandDms
            .filter { $0.command == "#UP#" }
            .map { Danmaku(upDm: $0) }
        dms.sort { $0.time < $1.time }
        upDanmakus = dms

        Logger.debug("[dm] cid:\(cid) up danmu cnt: \(dms.count)")
    }

    @MainActor
    func fetchDanmakuList(_ idx: Int) async {
        guard let cid else { return }
        var reply: DmSegMobileReply
        do {
            reply = try await WebRequest.requestDanmakuList(cid: cid, segmentIdx: idx)
        } catch let err {
            inFlightSegments.remove(idx) // 等待下次重试
            let failures = (segmentFailureCount[idx] ?? 0) + 1
            segmentFailureCount[idx] = failures
            // 2s → 4s → 8s → 16s → 30s 封顶；播放器每秒 tick 不会再打爆同一段。
            let delay = min(pow(2, Double(failures)), 30)
            segmentRetryAt[idx] = Date().addingTimeInterval(delay)
            Logger.warn("[dm] cid:\(cid) sidx:\(idx) requestDanmuList error: \(err)（\(Int(delay))s 后重试）")
            return
        }

        var dms = reply.elems
            .filter { $0.mode <= 5 }

        // 合并优先：把时间相邻的重复弹幕折叠成一条并标注 ×N；关掉合并时退回精确去重。
        // 顺序纪律：先合并、后（DanmakuViewPlugin 里的同屏）限流，别反。
        if Settings.danmakuMergeDuplicates {
            dms = Self.mergeRepeatedDanmaku(dms)
        } else if enableDanmakuRemoveDup {
            var set = Set<String>()
            dms = dms.filter { set.insert($0.content).inserted }
        }

        if enableDanmakuFilter {
            dms = dms.filter {
                VideoDanmakuFilter.shared.accept($0.content, midHash: $0.midHash)
            }
        }

        var models = dms
            .map { Danmaku(dm: $0) }
        models.sort { $0.time < $1.time }
        segmentDanmakus[idx] = models
        segmentRetryAt.removeValue(forKey: idx)
        segmentFailureCount.removeValue(forKey: idx)

        Logger.debug("[dm] cid:\(cid) sidx:\(idx) danmu cnt: \(dms.count)")
    }

    /// pakku 式重复弹幕合并：同一规范化文本 + 同模式、首次出现时间相距在 window 毫秒内的多条，
    /// 折叠为最早的一条并在末尾追加「 ×N」。返回按 progress 升序。
    /// 规范化去掉空白与标点（全角转半角、大小写不敏感），故「哈哈哈！！！」与「哈哈哈」视为同一条。
    static func mergeRepeatedDanmaku(_ elems: [DanmakuElem], window: Int64 = 5000) -> [DanmakuElem] {
        var slotByKey = [String: Int]()
        var baseTextByKey = [String: String]()
        var countByKey = [String: Int]()
        var out = [DanmakuElem]()
        for dm in elems.sorted(by: { $0.progress < $1.progress }) {
            let key = "\(dm.mode)#\(normalizedDanmakuText(dm.content))"
            if let idx = slotByKey[key], dm.progress - out[idx].progress <= window {
                let n = (countByKey[key] ?? 1) + 1
                countByKey[key] = n
                var kept = out[idx]
                kept.content = (baseTextByKey[key] ?? kept.content) + " ×\(n)"
                out[idx] = kept
            } else {
                slotByKey[key] = out.count
                baseTextByKey[key] = dm.content
                countByKey[key] = 1
                out.append(dm)
            }
        }
        return out
    }

    /// 归一化弹幕文本：去空白、去标点、全角转半角、大小写不敏感，作为「同一条」的判据
    static func normalizedDanmakuText(_ text: String) -> String {
        let folded = text.folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
        let kept = folded.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }
        let result = String(String.UnicodeScalarView(kept))
        return result.isEmpty ? folded.trimmingCharacters(in: .whitespacesAndNewlines) : result
    }

    private let advancedDuration = 30 // 提前x秒加载下段弹幕
    private func fetchMoreDanmakuInBackground(time: TimeInterval) {
        func fetchDanmakuInBackground(_ idx: Int) {
            if let retryAt = segmentRetryAt[idx], retryAt > Date() { return }
            inFlightSegments.insert(idx)
            // fetchDanmakuList 是 @MainActor，普通 Task 会把状态写入收敛回主线程；
            // 网络请求在其内部 async 调用，不占主线程
            Task {
                await self.fetchDanmakuList(idx)
            }
            Logger.debug("[dm] cid:\(cid ?? -1) time:\(Int(time)) fetching sidx:\(idx)")
        }

        let sidx = getSegmentIdx(time: time)

        if !inFlightSegments.contains(sidx) {
            fetchDanmakuInBackground(sidx)
        }

        if sidx > 1, !inFlightSegments.contains(sidx - 1),
           Int(time) % segmentDuration < advancedDuration
        {
            fetchDanmakuInBackground(sidx - 1)
        }

        if !inFlightSegments.contains(sidx + 1),
           segmentDuration - Int(time) % segmentDuration < advancedDuration
        {
            fetchDanmakuInBackground(sidx + 1)
        }
    }

    func playerTimeChange(time: TimeInterval) {
        guard cid != nil else { return }

        fetchMoreDanmakuInBackground(time: time)
        let sidx = getSegmentIdx(time: time)
        guard let dms = segmentDanmakus[sidx] else { return }

        let diff = time - lastTime
        if diff > 5 || diff < 0 {
            danmakuIdx = dms.firstIndex(where: { $0.time > time }) ?? dms.count
            upDanmakuIdx = upDanmakus.firstIndex(where: { $0.time > time }) ?? upDanmakus.count
        } else if sidx == lastSegmentIdx + 1 {
            danmakuIdx = 0
        }
        lastTime = time
        lastSegmentIdx = sidx

        while upDanmakuIdx < upDanmakus.count {
            let dm = upDanmakus[upDanmakuIdx]
            guard dm.time < time else { break }
            upDanmakuIdx += 1
            let model = DanmakuTextCellModel(dm: dm)
            onSendTextModel.send(model)
        }

        while danmakuIdx < dms.count {
            let dm = dms[danmakuIdx]
            guard dm.time < time else { break }
            danmakuIdx += 1
            if dm.aiLevel < Settings.danmakuAILevel { continue }
            let model = DanmakuTextCellModel(dm: dm)
            onSendTextModel.send(model)
        }
    }
}
