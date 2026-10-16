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

/// 视频弹幕数据源。可变状态(cid/segmentDanmakus/segmentStatuses/upDanmakus 及游标)只在主线程读写：
/// 网络请求是 async 调用不占主线程，状态的变更全部收敛在 @MainActor 方法内，
/// 避免后台 Task 写、playerTimeChange 主线程读的竞态
class VideoDanmakuProvider: DanmakuProviderProtocol {
    private var cid: Int?
    private let enableDanmakuFilter: Bool
    private let enableDanmakuRemoveDup: Bool
    private var allDanmakus = [Danmaku]()
    private var playingDanmakus = [Danmaku]()

    let observerPlayerTime: Bool = true
    let onSendTextModel = PassthroughSubject<DanmakuTextCellModel, Never>()

    private var upDanmakus = [Danmaku]()
    private static let segmentMinCap = 5
    private var segmentDanmakus = [Int: [Danmaku]](minimumCapacity: segmentMinCap)
    private var segmentStatuses = [Int: Any](minimumCapacity: segmentMinCap)

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
        segmentStatuses.removeAll(keepingCapacity: true)
        lastTime = 0
        lastSegmentIdx = 0
        upDanmakuIdx = 0
        danmakuIdx = 0

        async let view: () = fetchDanmakuView()
        let segmentIdx = getSegmentIdx(time: TimeInterval(startPos))
        segmentStatuses[segmentIdx] = true
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
            segmentStatuses[idx] = nil // 等待下次重试
            Logger.warn("[dm] cid:\(cid) sidx:\(idx) requestDanmuList error: \(err)")
            return
        }

        var dms = reply.elems
            .filter { $0.mode <= 5 }

        if enableDanmakuRemoveDup {
            var set = Set<String>()
            dms = dms.filter { set.insert($0.content).inserted }
        }

        if enableDanmakuFilter {
            dms = dms.filter {
                VideoDanmakuFilter.shared.accept($0.content)
            }
        }

        var models = dms
            .map { Danmaku(dm: $0) }
        models.sort { $0.time < $1.time }
        segmentDanmakus[idx] = models

        Logger.debug("[dm] cid:\(cid) sidx:\(idx) danmu cnt: \(dms.count)")
    }

    private let advancedDuration = 30 // 提前x秒加载下段弹幕
    private func fetchMoreDanmakuInBackground(time: TimeInterval) {
        func fetchDanmakuInBackground(_ idx: Int) {
            segmentStatuses[idx] = true
            // fetchDanmakuList 是 @MainActor，普通 Task 会把状态写入收敛回主线程；
            // 网络请求在其内部 async 调用，不占主线程
            Task {
                await self.fetchDanmakuList(idx)
            }
            Logger.debug("[dm] cid:\(cid ?? -1) time:\(Int(time)) fetching sidx:\(idx)")
        }

        let sidx = getSegmentIdx(time: time)

        if segmentStatuses[sidx].isNil() {
            fetchDanmakuInBackground(sidx)
        }

        if sidx > 1, segmentStatuses[sidx - 1].isNil(),
           Int(time) % segmentDuration < advancedDuration
        {
            fetchDanmakuInBackground(sidx - 1)
        }

        if segmentStatuses[sidx + 1].isNil(),
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
