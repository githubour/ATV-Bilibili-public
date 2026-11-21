//
//  DanmakuView.swift
//  DanmakuKit
//
//  Created by Q YiZhong on 2020/8/16.
//

import UIKit

public enum DanmakuStatus {
    case play
    case pause
    case stop
}

/// The number of queues to draw the danmaku. If you want to change it, you must do so before the danmakuView is first created.
public var DRAW_DANMAKU_QUEUE_COUNT = 16

public class DanmakuView: UIView {
    /// If this property is false, the danmaku will not be reused and danmakuView(_:dequeueReusable danmaku:) methods will not be called.
    public var enableCellReusable = true

    /// Each danmaku is in one track and the number of tracks in the view depends on the height of the track.
    public var trackHeight: CGFloat = 20 {
        didSet {
            guard oldValue != trackHeight else { return }
            recaculateTracks()
        }
    }

    /// Padding of top area, the actual offset of the top danmaku will refer to this property.
    public var paddingTop: CGFloat = 0 {
        didSet {
            guard oldValue != paddingTop else { return }
            recaculateTracks()
        }
    }

    /// Padding of bottom area, the actual offset of the bottom danmaku will refer to this property.
    public var paddingBottom: CGFloat = 0 {
        didSet {
            guard oldValue != paddingBottom else { return }
            recaculateTracks()
        }
    }

    /// State of play,  The danmaku can only be sent in play status.
    public private(set) var status: DanmakuStatus = .stop

    /// The display area of the danmaku is set between 0 and 1. Setting this property will affect the number of danmaku tracks.
    public var displayArea: CGFloat = 1.0 {
        willSet {
            assert(newValue >= 0 && newValue <= 1, "Danmaku display area must be between [0, 1].")
        }
        didSet {
            guard oldValue != displayArea else { return }
            recaculateTracks()
        }
    }

    /// If this property is true, the danmaku supports overlapping launches. Default is false.
    public var isOverlap: Bool = false {
        didSet {
            var tracks = allTracks
            for i in tracks.indices {
                tracks[i].isOverlap = isOverlap
            }
        }
    }

    /// 同屏弹幕上限，0 = 不限。达到上限后新弹幕不再入场，按类型回调 `noSpaceShoot` / `noSpaceSync`。
    /// 高密度稿件（每秒几十条）里，无限入场会让同屏 CALayer 与待渲染位图堆到几百个，
    /// 既拖慢主线程也让播放帧率掉下来；限流优先保住正在播放的画面。默认不限，由使用方按需设置。
    public var maxOnScreenCount: Int = 0

    /// All floating danmaku are removed immediately after set false, and it won't be launched again. Default is true.
    public var enableFloatingDanmaku: Bool = true {
        didSet {
            if !enableFloatingDanmaku {
                for floatingTrack in floatingTracks {
                    floatingTrack.stop()
                }
            }
        }
    }

    /// All top danmaku are removed immediately after set false, and it won't be launched again. Default is true.
    public var enableTopDanmaku: Bool = true {
        didSet {
            if !enableTopDanmaku {
                for topTrack in topTracks {
                    topTrack.stop()
                }
            }
        }
    }

    /// All bottom danmaku are removed immediately after set false, and it won't be launched again. Default is true.
    public var enableBottomDanmaku: Bool = true {
        didSet {
            if !enableBottomDanmaku {
                for bottomTrack in bottomTracks {
                    bottomTrack.stop()
                }
            }
        }
    }

    public var playingSpeed: Float = 1.0 {
        willSet {
            assert(newValue > 0, "Danmaku playing speed must be over 0.")
        }
        didSet {
            update {
                var tracks = allTracks
                for i in tracks.indices {
                    tracks[i].playingSpeed = playingSpeed
                }
            }
        }
    }

    private var danmakuPool: [String: [DanmakuCell]] = [:]

    private var floatingTracks: [DanmakuTrack] = []

    private var topTracks: [DanmakuTrack] = []

    private var bottomTracks: [DanmakuTrack] = []

    /// 三条轨道的扁平视图（顺序 = 浮动→顶部→底部），供遍历/查找类方法统一使用
    private var allTracks: [DanmakuTrack] {
        floatingTracks + topTracks + bottomTracks
    }

    private var viewHeight: CGFloat {
        return bounds.height * displayArea
    }

    /// 当前还在屏幕上的弹幕总数（三条轨道各自计数），用于 `maxOnScreenCount` 限流
    private var onScreenDanmakuCount: Int {
        allTracks.reduce(0) { $0 + $1.danmakuCount }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        createPoolIfNeed()
        recaculateTracks()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

public extension DanmakuView {
    func shoot(danmaku: DanmakuCellModel) {
        guard status == .play else { return }
        switch danmaku.type {
        case .floating:
            guard enableFloatingDanmaku else { return }
            guard !floatingTracks.isEmpty else { return }
        case .top:
            guard enableTopDanmaku else { return }
            guard !topTracks.isEmpty else { return }
        case .bottom:
            guard enableBottomDanmaku else { return }
            guard !bottomTracks.isEmpty else { return }
        }

        guard maxOnScreenCount <= 0 || onScreenDanmakuCount < maxOnScreenCount else { return }

        guard let cell = obtainCell(with: danmaku) else { return }

        let shootTrack: DanmakuTrack
        if isOverlap {
            shootTrack = findLeastNumberDanmakuTrack(for: danmaku)
        } else {
            guard let t = findSuitableTrack(for: danmaku) else { return }
            shootTrack = t
        }

        if cell.superview == nil {
            addSubview(cell)
        }

        cell.layer.setNeedsDisplay()
        shootTrack.shoot(danmaku: cell)
    }

    func canShoot(danmaku: DanmakuCellModel) -> Bool {
        guard status == .play else { return false }
        switch danmaku.type {
        case .floating:
            guard enableFloatingDanmaku else { return false }
            return (floatingTracks.first { t -> Bool in
                return t.canShoot(danmaku: danmaku)
            }) != nil
        case .top:
            guard enableTopDanmaku else { return false }
            return (topTracks.first { t -> Bool in
                return t.canShoot(danmaku: danmaku)
            }) != nil
        case .bottom:
            guard enableBottomDanmaku else { return false }
            return (bottomTracks.first { t -> Bool in
                return t.canShoot(danmaku: danmaku)
            }) != nil
        }
    }

    /// You can call this method when you need to change the size of the danmakuView.
    func recaculateTracks() {
        recaculateFloatingTracks()
        recaculateTopTracks()
        recaculateBottomTracks()
    }

    func play() {
        guard status != .play else { return }
        allTracks.forEach { $0.play() }
        status = .play
    }

    func pause() {
        guard status != .pause else { return }
        allTracks.forEach { $0.pause() }
        status = .pause
    }

    func stop() {
        guard status != .stop else { return }
        allTracks.forEach { $0.stop() }
        status = .stop
    }

    @discardableResult
    func play(_ danmaku: DanmakuCellModel) -> Bool {
        // allTracks 顺序（浮动→顶部→底部）即原先的三段查找顺序，contains 短路等价
        allTracks.contains { $0.play(danmaku) }
    }

    @discardableResult
    func pause(_ danmaku: DanmakuCellModel) -> Bool {
        allTracks.contains { $0.pause(danmaku) }
    }

    /// Display a danmaku synchronously according to the progress. If the status is stop, it will not work.
    /// - Parameters:
    ///   - danmaku: danmakuCellModel
    ///   - progress: progress of danmaku display
    func sync(danmaku: DanmakuCellModel, at progress: Float) {
        guard status != .stop else { return }
        assert(progress <= 1.0, "Cannot sync danmaku at progress \(progress).")
        switch danmaku.type {
        case .floating:
            guard enableFloatingDanmaku else { return }
            guard !floatingTracks.isEmpty else { return }
        case .top:
            guard enableTopDanmaku else { return }
            guard !topTracks.isEmpty else { return }
        case .bottom:
            guard enableBottomDanmaku else { return }
            guard !bottomTracks.isEmpty else { return }
        }

        guard maxOnScreenCount <= 0 || onScreenDanmakuCount < maxOnScreenCount else { return }

        guard let cell = obtainCell(with: danmaku) else { return }

        let syncTrack: DanmakuTrack
        if isOverlap {
            syncTrack = findLeastNumberDanmakuTrack(for: danmaku)
        } else {
            guard let t = findSuitableSyncTrack(for: danmaku, at: progress) else { return }
            syncTrack = t
        }

        if cell.superview == nil {
            addSubview(cell)
        }

        cell.layer.setNeedsDisplay()
        if status == .play {
            syncTrack.syncAndPlay(cell, at: progress)
        } else {
            syncTrack.sync(cell, at: progress)
        }
    }

    /// Clean all the currently displayed danmaku.
    func clean() {
        floatingTracks.forEach { $0.clean() }
        bottomTracks.forEach { $0.clean() }
        topTracks.forEach { $0.clean() }
    }

    /// When you change some properties of the danmakuView or cellModel that might affect the danmaku, you must make changes in the closure of this method.
    /// E.g.This method will be used when you change the displayTime property in the cellModel.
    /// - Parameter closure: update closure
    func update(_ closure: () -> Void) {
        pause()
        closure()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            self.play()
        }
    }
}

private extension DanmakuView {
    func recaculateFloatingTracks() {
        if viewHeight == 0 { return }
        let trackCount = Int(floorf(Float((viewHeight - paddingTop - paddingBottom) / trackHeight)))
        let offsetY = max(0, (viewHeight - CGFloat(trackCount) * trackHeight) / 2.0)
        let diffFloatingTrackCount = trackCount - floatingTracks.count
        if diffFloatingTrackCount > 0 {
            for _ in 0..<diffFloatingTrackCount {
                floatingTracks.append(DanmakuFloatingTrack(view: self))
            }
        } else if diffFloatingTrackCount < 0 {
            for i in max(0, floatingTracks.count + diffFloatingTrackCount)..<floatingTracks.count {
                floatingTracks[i].stop()
            }
            floatingTracks.removeLast(Int(abs(diffFloatingTrackCount)))
        }
        for i in 0..<floatingTracks.count {
            var track = floatingTracks[i]
            track.stopClosure = { [weak self] cell in
                guard let strongSelf = self else { return }
                strongSelf.cellPlayingStop(cell)
            }
            track.index = UInt(i)
            track.positionY = CGFloat(i) * trackHeight + trackHeight / 2.0 + paddingTop + offsetY
        }
    }

    func recaculateTopTracks() {
        if viewHeight == 0 { return }
        let trackCount = Int(floorf(Float((viewHeight - paddingTop - paddingBottom) / trackHeight)))
        let offsetY = max(0, (viewHeight - CGFloat(trackCount) * trackHeight) / 2.0)
        let diffFloatingTrackCount = trackCount - topTracks.count
        if diffFloatingTrackCount > 0 {
            for _ in 0..<diffFloatingTrackCount {
                topTracks.append(DanmakuVerticalTrack(view: self))
            }
        } else if diffFloatingTrackCount < 0 {
            for i in max(0, topTracks.count + diffFloatingTrackCount)..<topTracks.count {
                topTracks[i].stop()
            }
            topTracks.removeLast(Int(abs(diffFloatingTrackCount)))
        }
        for i in 0..<topTracks.count {
            var track = topTracks[i]
            track.stopClosure = { [weak self] cell in
                guard let strongSelf = self else { return }
                strongSelf.cellPlayingStop(cell)
            }
            track.index = UInt(i)
            track.positionY = CGFloat(i) * trackHeight + trackHeight / 2.0 + paddingTop + offsetY
        }
    }

    func recaculateBottomTracks() {
        if viewHeight == 0 { return }
        let trackCount = Int(floorf(Float((viewHeight - paddingTop - paddingBottom) / trackHeight)))
        let offsetY = max(0, (viewHeight - CGFloat(trackCount) * trackHeight) / 2.0)
        let diffFloatingTrackCount = trackCount - bottomTracks.count
        if diffFloatingTrackCount > 0 {
            for _ in 0..<diffFloatingTrackCount {
                bottomTracks.insert(DanmakuVerticalTrack(view: self), at: 0)
            }
        } else if diffFloatingTrackCount < 0 {
            for i in 0..<min(bottomTracks.count, abs(diffFloatingTrackCount)) {
                bottomTracks[i].stop()
            }
            bottomTracks.removeFirst(Int(abs(diffFloatingTrackCount)))
        }
        for i in (0..<bottomTracks.count).reversed() {
            var track = bottomTracks[i]
            track.stopClosure = { [weak self] cell in
                guard let strongSelf = self else { return }
                strongSelf.cellPlayingStop(cell)
            }
            let index = bottomTracks.count - i - 1
            track.index = UInt(index)
            track.positionY = bounds.height - CGFloat(index) * trackHeight - trackHeight / 2.0 - paddingTop - offsetY
        }
    }

    func findLeastNumberDanmakuTrack(for danmaku: DanmakuCellModel) -> DanmakuTrack {
        func findLeastNumberDanmaku(from tracks: [DanmakuTrack]) -> DanmakuTrack {
            // Find a track with the minimum danmaku number
            var index = 0
            var value = Int.max
            for i in 0..<tracks.count {
                let track = tracks[i]
                if track.danmakuCount < value {
                    value = track.danmakuCount
                    index = i
                }
            }
            return tracks[index]
        }
        switch danmaku.type {
        case .floating:
            return findLeastNumberDanmaku(from: floatingTracks)
        case .top:
            return findLeastNumberDanmaku(from: topTracks)
        case .bottom:
            return findLeastNumberDanmaku(from: bottomTracks)
        }
    }

    func findSuitableTrack(for danmaku: DanmakuCellModel) -> DanmakuTrack? {
        switch danmaku.type {
        case .floating:
            guard let track = floatingTracks.first(where: { t -> Bool in
                return t.canShoot(danmaku: danmaku)
            }) else {
                return nil
            }
            return track
        case .top:
            guard let track = topTracks.first(where: { t -> Bool in
                return t.canShoot(danmaku: danmaku)
            }) else {
                return nil
            }
            return track
        case .bottom:
            guard let track = bottomTracks.last(where: { t -> Bool in
                return t.canShoot(danmaku: danmaku)
            }) else {
                return nil
            }
            return track
        }
    }

    func findSuitableSyncTrack(for danmaku: DanmakuCellModel, at progress: Float) -> DanmakuTrack? {
        switch danmaku.type {
        case .floating:
            guard let track = floatingTracks.first(where: { t -> Bool in
                return t.canSync(danmaku, at: progress)
            }) else {
                return nil
            }
            return track
        case .top:
            guard let track = topTracks.first(where: { t -> Bool in
                return t.canSync(danmaku, at: progress)
            }) else {
                return nil
            }
            return track
        case .bottom:
            guard let track = bottomTracks.last(where: { t -> Bool in
                return t.canSync(danmaku, at: progress)
            }) else {
                return nil
            }
            return track
        }
    }

    func obtainCell(with danmaku: DanmakuCellModel) -> DanmakuCell? {
        var cell: DanmakuCell?
        if enableCellReusable {
            var cells = danmakuPool[NSStringFromClass(danmaku.cellClass)]
            if cells == nil {
                cells = []
            }
            cell = (cells?.count ?? 0) > 0 ? cells?.removeFirst() : nil
            danmakuPool[NSStringFromClass(danmaku.cellClass)] = cells
        }

        let frame = CGRect(x: bounds.width, y: 0, width: danmaku.size.width, height: danmaku.size.height)
        if cell == nil {
            guard let cls = NSClassFromString(NSStringFromClass(danmaku.cellClass)) as? DanmakuCell.Type else {
                assertionFailure("Launched Danmaku must inherit from DanmakuCell!")
                return nil
            }
            cell = cls.init(frame: frame)
            cell?.model = danmaku
        } else {
            cell?.frame = frame
            cell?.model = danmaku
        }
        return cell
    }

    func cellPlayingStop(_ cell: DanmakuCell) {
        guard enableCellReusable else { return }
        guard let cs = cell.model?.cellClass else { return }
        guard var array = danmakuPool[NSStringFromClass(cs)] else { return }
        array.append(cell)
        danmakuPool[NSStringFromClass(cs)] = array
    }

    func createPoolIfNeed() {
        guard pool == nil else { return }
        pool = DanmakuQueuePool(name: "com.DanmakuKit.DanmakuAsynclayer", queueCount: DRAW_DANMAKU_QUEUE_COUNT, qos: .userInteractive)
    }
}
