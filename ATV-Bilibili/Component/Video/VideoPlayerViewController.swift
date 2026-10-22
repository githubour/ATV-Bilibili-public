//
//  VideoPlayerViewController.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2024/5/23.
//

import AVKit
import Combine
import UIKit

struct PlayInfo: Hashable {
    var aid: Int
    var cid: Int? = 0
    var epid: Int? = 0 // 港澳台解锁需要
    var seasonId: Int? = 0 // 番剧 season_id
    var subType: Int? = nil // 0: 普通视频 1：番剧 2：电影 3：纪录片 4：国创 5：电视剧 7：综艺
    var lastPlayCid: Int?
    var playTimeInSecond: Int?
    var title: String?
    var ownerName: String?
    var coverURL: URL?

    var isCidValid: Bool {
        return cid ?? 0 > 0
    }

    var isBangumi: Bool {
        return epid ?? 0 > 0 || seasonId ?? 0 > 0
    }

    var sequenceKey: String {
        "\(aid)-\(cid ?? 0)-\(epid ?? 0)-\(seasonId ?? 0)"
    }

    var contentIdentity: String {
        if let epid, epid > 0 { return "epid-\(epid)" }
        if let seasonId, seasonId > 0 { return "season-\(seasonId)" }
        return "aid-\(aid)"
    }

    var contextKey: PlayContextKey {
        PlayContextKey(aid: aid,
                       cid: cid ?? 0,
                       epid: epid ?? 0,
                       seasonId: seasonId ?? 0)
    }
}

enum VideoPlayerMode {
    case regular
    case preview
    case feedFlow
}

/// 连播推进方向。倒序只播已加载的序列，播到第一条即结束（不会向前补页）。
enum SequencePlayDirection {
    case forward
    case reverse
}

@MainActor
final class VideoSequenceProvider {
    private(set) var playSeq: [PlayInfo]
    private(set) var currentIndex: Int
    private(set) var temporaryOverrides = [PlayInfo]()
    /// 队列来源：自动连播策略据此判断是否应该跨集推进
    let kind: PlaybackQueueKind
    private let preloadThreshold: Int
    var onNeedMore: (() async -> Void)?

    init(seq: [PlayInfo],
         currentIndex: Int = 0,
         kind: PlaybackQueueKind,
         preloadThreshold: Int = 8)
    {
        playSeq = seq.uniqued()
        self.currentIndex = max(0, min(currentIndex, max(playSeq.count - 1, 0)))
        self.kind = kind
        self.preloadThreshold = preloadThreshold
    }

    var count: Int {
        playSeq.count
    }

    var hasPrevious: Bool {
        currentIndex > 0
    }

    var hasNext: Bool {
        currentIndex + 1 < playSeq.count
    }

    func current() -> PlayInfo? {
        if let temporary = temporaryOverrides.last {
            return temporary
        }
        guard playSeq.indices.contains(currentIndex) else { return nil }
        return playSeq[currentIndex]
    }

    func setCurrentIndex(_ index: Int) {
        guard playSeq.indices.contains(index) else { return }
        clearTemporaryOverrides()
        currentIndex = index
    }

    func reset() {
        clearTemporaryOverrides()
        currentIndex = 0
    }

    func append(_ seq: [PlayInfo]) {
        var existing = Set(playSeq.map(\.sequenceKey))
        let newItems = seq.filter { existing.insert($0.sequenceKey).inserted }
        playSeq.append(contentsOf: newItems)
    }

    func peekPrevious() -> PlayInfo? {
        guard hasPrevious else { return nil }
        return playSeq[currentIndex - 1]
    }

    func peekNext() -> PlayInfo? {
        guard hasNext else { return nil }
        return playSeq[currentIndex + 1]
    }

    func neighborItems(radius: Int) -> [PlayInfo] {
        guard !playSeq.isEmpty else { return temporaryOverrides.uniqued() }
        let lower = max(0, currentIndex - radius)
        let upper = min(playSeq.count - 1, currentIndex + radius)
        return ([current()].compactMap { $0 } + Array(playSeq[lower...upper])).uniqued()
    }

    func pushTemporary(_ playInfo: PlayInfo) {
        temporaryOverrides.append(playInfo)
    }

    func clearTemporaryOverrides() {
        temporaryOverrides.removeAll()
    }

    func movePrevious() -> PlayInfo? {
        guard hasPrevious else { return nil }
        clearTemporaryOverrides()
        currentIndex -= 1
        return playSeq[currentIndex]
    }

    func moveNext() async -> PlayInfo? {
        await prefetchMoreIfNeeded()
        guard hasNext else { return nil }
        clearTemporaryOverrides()
        currentIndex += 1
        await prefetchMoreIfNeeded()
        return playSeq[currentIndex]
    }

    func prefetchMoreIfNeeded() async {
        guard count - currentIndex - 1 < preloadThreshold else { return }
        await onNeedMore?()
    }
}

class VideoPlayerViewController: CommonPlayerViewController {
    enum AutoTriggeredInfoAction: String {
        case previous
        case next

        /// 面板展示用文案，匹配与创建都走这里，改文案不会失联
        var title: String {
            switch self {
            case .previous: return "上一条"
            case .next: return "下一条"
            }
        }
    }

    var sequenceProvider: VideoSequenceProvider?
    /// 自动连播的推进方向，需在 present 之前设好（viewDidLoad 会传给 viewModel）
    var sequencePlayDirection: SequencePlayDirection = .forward
    var onLoadFailure: ((String) -> Void)?
    var onPlaybackStarted: (() -> Void)?
    var onPlayInfoChanged: ((PlayInfo) -> Void)?
    var onDismissWithPlayInfo: ((PlayInfo) -> Void)?

    private let playMode: VideoPlayerMode
    private let playContextCache: PlayContextCache?
    private let mediaWarmupManager: PlayerMediaWarmupManager?
    private let previewMuted: Bool
    private let viewModel: VideoPlayerViewModel
    private var cancelable = Set<AnyCancellable>()
    private var neighborPreloadTask: Task<Void, Never>?
    private var currentRetryKey: String
    private var hasRetriedCurrentItem = false
    private var isStopping = false

    init(playInfo: PlayInfo,
         playMode: VideoPlayerMode = .regular,
         isIncognito: Bool = false,
         playContextCache: PlayContextCache? = nil,
         mediaWarmupManager: PlayerMediaWarmupManager? = nil,
         previewMuted: Bool = true,
         startTimeOverride: Int? = nil,
         initialDetail: VideoDetail? = nil,
         initialPlayerInfo: PlayerInfo? = nil)
    {
        self.playMode = playMode
        self.playContextCache = playContextCache
        self.mediaWarmupManager = mediaWarmupManager
        self.previewMuted = previewMuted
        viewModel = VideoPlayerViewModel(playInfo: playInfo,
                                         playMode: playMode,
                                         isIncognito: isIncognito,
                                         playContextCache: playContextCache,
                                         mediaWarmupManager: mediaWarmupManager,
                                         previewMuted: previewMuted,
                                         startTimeOverride: startTimeOverride,
                                         initialDetail: initialDetail,
                                         initialPlayerInfo: initialPlayerInfo)
        currentRetryKey = playInfo.sequenceKey
        super.init(nibName: nil, bundle: nil)
        if playMode == .preview {
            showsPlaybackControls = false
            allowsPictureInPicturePlayback = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentPlayInfo: PlayInfo {
        viewModel.currentPlayInfo
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        viewModel.sequenceProvider = sequenceProvider
        viewModel.sequenceDirection = sequencePlayDirection
        viewModel.onPlayInfoChanged = { [weak self] info in
            self?.handlePlayInfoChanged(info)
        }
        viewModel.onShowDetail = { [weak self] info in
            self?.showDetail(for: info)
        }
        viewModel.loadResult.receive(on: DispatchQueue.main).sink { [weak self] result in
            switch result {
            case let .failure(err):
                self?.handleLoadFailure(message: err)
            case let .success(plugins):
                self?.neighborPreloadTask?.cancel()
                self?.removeAllPlugins()
                plugins.forEach { self?.addPlugin(plugin: $0) }
                self?.neighborPreloadTask = Task { [weak self] in
                    await self?.viewModel.preloadNeighborsIfNeeded()
                }
            }
        }.store(in: &cancelable)

        if playMode != .preview {
            viewModel.onExit = { [weak self] in
                self?.dismiss(animated: true)
            }
        }

        if playMode == .feedFlow {
            // 添加双击上方向键切回上一条视频的全局手势拦截 (作为面板“上一条”被折叠的补偿方案)
            let doubleUpTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleUpTap))
            doubleUpTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.upArrow.rawValue)]
            doubleUpTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleUpTap)

            let doubleDownTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleDownTap))
            doubleDownTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.downArrow.rawValue)]
            doubleDownTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleDownTap)
        }

        viewModel.load()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        let isExiting = isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true
        let dismissPlayInfo = playMode == .feedFlow ? viewModel.currentPlayInfo : nil
        super.viewDidDisappear(animated)
        guard isExiting else { return }
        if playMode == .feedFlow {
            if let dismissPlayInfo {
                onDismissWithPlayInfo?(dismissPlayInfo)
            }
        }
        stopAsyncWork()
    }

    override func stopPlayback() {
        stopAsyncWork()
        super.stopPlayback()
    }

    override func playerDidStart(player: AVPlayer) {
        switch playMode {
        case .preview:
            onPlaybackStarted?()
        case .feedFlow, .regular:
            break
        }
    }

    override func playerDidStall(player: AVPlayer) {
        guard playMode == .feedFlow else { return }
        attemptRetryOrShowRecovery(message: "播放卡住了，请选择重试或切换下一条。")
    }

    override func playerDidFail(player: AVPlayer) {
        guard playMode == .feedFlow else {
            super.playerDidFail(player: player)
            return
        }
        attemptRetryOrShowRecovery(message: "当前视频加载失败，请选择重试或切换下一条。")
    }

    private func handlePlayInfoChanged(_ info: PlayInfo) {
        neighborPreloadTask?.cancel()
        neighborPreloadTask = nil
        if currentRetryKey != info.sequenceKey {
            currentRetryKey = info.sequenceKey
            hasRetriedCurrentItem = false
        }
        onPlayInfoChanged?(info)
    }

    private func stopAsyncWork() {
        guard !isStopping else { return }
        isStopping = true
        neighborPreloadTask?.cancel()
        neighborPreloadTask = nil
        viewModel.cancelLoading()
        cancelable.removeAll()
        Task { [mediaWarmupManager] in
            await mediaWarmupManager?.cancelAll()
        }
    }

    private func handleLoadFailure(message: String) {
        switch playMode {
        case .preview:
            onLoadFailure?(message)
        case .feedFlow:
            attemptRetryOrShowRecovery(message: message)
        case .regular:
            showErrorAlertAndExit(message: message)
        }
    }

    private func attemptRetryOrShowRecovery(message: String) {
        guard !hasRetriedCurrentItem else {
            showFeedFlowRecoveryAlert(message: message)
            return
        }
        hasRetriedCurrentItem = true
        viewModel.retryCurrent()
    }

    private func showFeedFlowRecoveryAlert(message: String) {
        let alert = UIAlertController(title: "播放异常", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in
            self?.viewModel.retryCurrent()
        })
        alert.addAction(UIAlertAction(title: AutoTriggeredInfoAction.next.title, style: .default) { [weak self] _ in
            Task { [weak self] in
                if await self?.viewModel.playNextFromSequence() == false {
                    self?.dismiss(animated: true)
                }
            }
        })
        alert.addAction(UIAlertAction(title: "关闭", style: .cancel))
        present(alert, animated: true)
    }

    private func showDetail(for info: PlayInfo) {
        guard playMode != .preview else { return }
        let detailVC: VideoDetailViewController
        if let seasonId = info.seasonId, seasonId > 0 {
            detailVC = VideoDetailViewController.create(seasonId: seasonId)
        } else {
            detailVC = VideoDetailViewController.create(aid: info.aid, cid: info.cid, epid: info.epid)
        }
        detailVC.present(from: self, directlyEnterVideo: false)
    }

    @objc private func handleDoubleUpTap() {
        guard playMode == .feedFlow else { return }
        Logger.debug("[FeedFlow] 捕获双击上键，准备切换至上一条")
        Task { [weak self] in
            guard let self else { return }
            _ = await self.viewModel.playPreviousFromSequence()
        }
    }

    @objc private func handleDoubleDownTap() {
        guard playMode == .feedFlow else { return }
        Logger.debug("[FeedFlow] 捕获双击下键，准备切换至下一条")
        Task { [weak self] in
            guard let self else { return }
            _ = await self.viewModel.playNextFromSequence()
        }
    }
}
