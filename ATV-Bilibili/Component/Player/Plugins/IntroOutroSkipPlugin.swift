//
//  IntroOutroSkipPlugin.swift
//  ATV-Bilibili
//
//  「片头片尾标记」插件：
//  - 「更多设置」独立齿轮按钮（传输栏顶级菜单，与「播放设置」「弹幕设置」并列）：
//    · 片头片尾组：标记当前进度为片头 / 片尾（副标题显示当前已标记时长）、
//      清除片头 / 清除片尾（未标记时置灰）、自动跳过片头 / 自动跳过片尾开关（默认开）
//    · 公共挂载点（.moreMenu）：CDN 测速 / Debug / 循环播放 / 查看详情也收在这里，
//      本插件必须排在 BVideoPlayPlugin / DebugPlugin / VideoPlayListPlugin 之前注册
//  - 标记点按内容键持久化（番剧按 season_id、普通视频按 aid，同一部番所有集共用）：
//    片头标记 = 片头结束时刻（绝对秒，跨集直接沿用，即「0 + 秒数」）；
//    片尾标记 = 片尾开始时刻，跨集按「总片长 - 标记时刻」换算 ED 长度后回推
//  - 自动跳过片头（开）：起播即从片头标记处开始（直接 seek 到标记点，不播放片头）
//  - 自动跳过片尾（开）：播放越过片尾标记点时直跳到结尾
//  - 手动模式（对应开关关闭）：传输栏出现「跳过片头」/「跳过片尾」按钮
//    （contextualActions：tvOS 上 contentOverlayView 里的自定义按钮抢不到焦点，
//    只有系统传输栏按钮可选；片头标记之前 / 片尾标记之后显示，按下跳到对应位置）
//  - 单集闩锁：自动跳过一次后置位，本集不再自动跳，换集重置
//  - 注意：tvOS 没有 setNeedsUpdateOfTransportBarCustomMenuItems，
//    菜单状态靠每次操作后经宿主 updateMenus() 重建，下次打开即最新
//

import AVKit
import SnapKit
import UIKit

class IntroOutroSkipPlugin: NSObject, CommonPlayerPlugin {
    /// 边界触发时播放位置与标记点的最大偏差，超过视为拖动定位
    private static let boundaryLeeway: Double = 2
    /// 手动模式按钮的轮询间隔（秒）
    private static let pollInterval: Double = 0.5
    /// 提示浮层停留时间
    private static let notifyDuration: TimeInterval = 2

    private enum MarkerKind {
        case intro
        case outro

        var skipButtonTitle: String {
            self == .intro ? "跳过片头" : "跳过片尾"
        }

        var autoSkipToast: String {
            self == .intro ? "已自动跳过片头" : "已自动跳过片尾"
        }

        var actionID: UIAction.Identifier {
            Self.actionID(for: self)
        }

        static func actionID(for kind: MarkerKind) -> UIAction.Identifier {
            kind == .intro ? introActionID : outroActionID
        }
    }

    private static let introActionID = UIAction.Identifier("com.example.bilibilitv.introOutroSkip.intro")
    private static let outroActionID = UIAction.Identifier("com.example.bilibilitv.introOutroSkip.outro")

    private weak var playerVC: AVPlayerViewController?
    private weak var player: AVPlayer?
    private weak var container: UIView?

    private var playInfo: PlayInfo
    /// 当前集生效的标记点（跨集时可能由同番其他集的记录换算而来）
    private var activeMarkers = SkipMarkers(introSeconds: nil, outroSeconds: nil, outroDuration: nil)
    private var currentDuration: Double = 0

    private var observers = [Any]()
    /// 时长 KVO：DASH 经资源加载器时长常晚于 readyToPlay 才确定，duration 落定后重装观察者
    private var durationToken: NSKeyValueObservation?
    /// 轮询兜底用的上一帧播放位置，用于判定"连续向前越过标记点"
    private var lastTickTime: Double = 0
    /// 单集自动跳过闩锁：自动跳过一次后置位，本集不再自动跳（回拖不重跳），换集重置
    private var introAutoSkipDone = false
    private var outroAutoSkipDone = false

    private var notifyView: UILabel?
    private var notifyTask: Task<Void, Never>?

    /// 宿主播放器，用于操作后重建菜单（刷新副标题/勾选态）
    private var hostVC: CommonPlayerViewController? {
        playerVC?.parent as? CommonPlayerViewController
    }

    init(playInfo: PlayInfo) {
        self.playInfo = playInfo
        super.init()
    }

    // MARK: - 标记点解析

    private func refreshMarkers() {
        let stored = SkipMarkerStore.markers(for: playInfo)
        currentDuration = 0
        activeMarkers = stored
        if let player,
           let duration = player.currentItem?.duration.seconds,
           duration.isFinite, duration > 0
        {
            currentDuration = duration
            activeMarkers = SkipMarkerResolver.resolveMarkers(stored, duration: duration)
        }
        Logger.info("[introOutro] key=\(SkipMarkerStore.key(for: playInfo)) storedIntro=\(stored.introSeconds.map { String(format: "%.1f", $0) } ?? "nil") storedOutro=\(stored.outroSeconds.map { String(format: "%.1f", $0) } ?? "nil") duration=\(Int(currentDuration)) resolvedIntro=\(activeMarkers.introSeconds.map { String(format: "%.1f", $0) } ?? "nil")")
        installSkipObservers()
    }

    // MARK: - CommonPlayerPlugin

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
    }

    func addViewToPlayerOverlay(container: UIView) {
        self.container = container
    }

    func playerDidChange(player: AVPlayer) {
        self.player = player
    }

    /// 新 item ready（起播/换集/换画质）后重算标记并重挂观察者
    func playerWillStart(player: AVPlayer) {
        refreshMarkers()
    }

    /// 换集（新 AVPlayerItem）：重置单集闩锁
    func playerItemDidChange(playerItem: AVPlayerItem) {
        introAutoSkipDone = false
        outroAutoSkipDone = false
        lastTickTime = 0
    }

    /// 起播立刻评估一次按钮区间（覆盖起播即处于片头区间的场景），后续由轮询接管
    func playerDidStart(player: AVPlayer) {
        handleTick(player.currentTime().seconds)
    }

    func playerWillCleanUp(playerVC: AVPlayerViewController) {
        removeAllObservers()
    }

    func playerDidCleanUp(player: AVPlayer) {
        removeAllObservers()
        playerVC?.contextualActions = []
        notifyTask?.cancel()
        notifyView?.removeFromSuperview()
        notifyView = nil
    }

    // MARK: - 菜单

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        let stored = SkipMarkerStore.markers(for: playInfo)

        // —— 片头组 ——
        let markIntro = UIAction(title: "标记当前进度为片头") { [weak self] _ in
            self?.markIntro()
        }
        markIntro.subtitle = Self.markerSubtitle(kind: .intro, markers: stored)
        let clearIntro = UIAction(title: "清除片头") { [weak self] _ in
            self?.clearMarker(.intro)
        }
        clearIntro.attributes = stored.introSeconds == nil ? [.disabled] : []
        let introGroup = UIMenu(options: .displayInline, children: [markIntro, clearIntro])

        // —— 片尾组 ——
        let markOutro = UIAction(title: "标记当前进度为片尾") { [weak self] _ in
            self?.markOutro()
        }
        markOutro.subtitle = Self.markerSubtitle(kind: .outro, markers: stored)
        let clearOutro = UIAction(title: "清除片尾") { [weak self] _ in
            self?.clearMarker(.outro)
        }
        clearOutro.attributes = stored.outroSeconds == nil ? [.disabled] : []
        let outroGroup = UIMenu(options: .displayInline, children: [markOutro, clearOutro])

        // —— 开关组 ——
        // tvOS 菜单只在 updateMenus() 时重建，切完必须重建，否则重开菜单勾选态
        // 还是旧值，用户再点一次又翻回去（表现为"取消不掉"）
        let autoIntro = UIAction(title: "自动跳过片头",
                                 state: Settings.skipIntroAutoEnabled ? .on : .off)
        { [weak self] _ in
            Settings.skipIntroAutoEnabled.toggle()
            self?.introAutoSkipDone = false
            self?.hostVC?.updateMenus()
        }
        let autoOutro = UIAction(title: "自动跳过片尾",
                                 state: Settings.skipOutroAutoEnabled ? .on : .off)
        { [weak self] _ in
            Settings.skipOutroAutoEnabled.toggle()
            self?.outroAutoSkipDone = false
            self?.hostVC?.updateMenus()
        }
        let toggleGroup = UIMenu(options: .displayInline, children: [autoIntro, autoOutro])

        // 顶级菜单 = 传输栏独立齿轮按钮；带 .moreMenu 标识，
        // CDN 测速/Debug/循环播放/查看详情等条目也挂进这里（见各插件 insertIntoMenu）
        return [UIMenu(title: "更多设置",
                       image: UIImage(systemName: "gearshape"),
                       identifier: .moreMenu,
                       children: [introGroup, outroGroup, toggleGroup])]
    }

    /// 副标题：已标记 → 「已标记时长：N 秒」（片头为 OP 长度，片尾为 ED 长度）；
    /// 片尾没记录片长时退回「标记于 mm:ss」；未标记 → 「未标记」
    private static func markerSubtitle(kind: MarkerKind, markers: SkipMarkers) -> String {
        switch kind {
        case .intro:
            guard let intro = markers.introSeconds else { return "未标记" }
            return "已标记时长：\(Int(intro.rounded()))秒"
        case .outro:
            guard let outro = markers.outroSeconds else { return "未标记" }
            if let recorded = markers.outroDuration, recorded > 0, recorded - outro > 0 {
                return "已标记时长：\(Int((recorded - outro).rounded()))秒"
            }
            return "标记于 \(TimeInterval(outro).timeString())"
        }
    }

    // MARK: - 标记动作

    private func markIntro() {
        guard let player else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0.5 else {
            showNotify("当前时刻无效，无法标记片头")
            return
        }
        SkipMarkerStore.setIntro(seconds, for: playInfo)
        Logger.info("[introOutro] marked intro \(String(format: "%.1f", seconds))s key=\(SkipMarkerStore.key(for: playInfo))")
        activeMarkers.introSeconds = seconds
        introAutoSkipDone = false
        installSkipObservers()
        showNotify(String(format: "已标记片头：正片从 %@ 开始", TimeInterval(seconds).timeString()))
        hostVC?.updateMenus()
    }

    private func markOutro() {
        guard let player else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0.5 else {
            showNotify("当前时刻无效，无法标记片尾")
            return
        }
        var duration: Double?
        if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
            currentDuration = itemDuration
        }
        SkipMarkerStore.setOutro(seconds, duration: duration, for: playInfo)
        activeMarkers = SkipMarkerResolver.resolveMarkers(SkipMarkerStore.markers(for: playInfo), duration: currentDuration)
        outroAutoSkipDone = false
        installSkipObservers()
        if let duration {
            showNotify(String(format: "已标记片尾：ED 约 %.0f 秒", duration - seconds))
        } else {
            showNotify("已标记片尾")
        }
        hostVC?.updateMenus()
    }

    private func clearMarker(_ kind: MarkerKind) {
        switch kind {
        case .intro:
            SkipMarkerStore.setIntro(nil, for: playInfo)
            activeMarkers.introSeconds = nil
            introAutoSkipDone = false
        case .outro:
            SkipMarkerStore.setOutro(nil, duration: nil, for: playInfo)
            activeMarkers.outroSeconds = nil
            activeMarkers.outroDuration = nil
            outroAutoSkipDone = false
        }
        installSkipObservers()
        clearSkipButtonIfOurs()
        showNotify(kind == .intro ? "已清除片头标记" : "已清除片尾标记")
        hostVC?.updateMenus()
    }

    // MARK: - 跳过观察者

    private func removeAllObservers() {
        if let player {
            observers.forEach { player.removeTimeObserver($0) }
        }
        observers.removeAll()
        removeDurationObserver()
    }

    private func removeDurationObserver() {
        durationToken?.invalidate()
        durationToken = nil
    }

    private func installSkipObservers() {
        guard let player else { return }
        removeAllObservers()
        lastTickTime = 0

        // 片尾自动跳过：播放越过片尾标记点时触发（片头改用起播即跳，不走边界）
        if let outro = activeMarkers.outroSeconds, outro > 0,
           currentDuration <= 0 || outro < currentDuration
        {
            let observer = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: outro, preferredTimescale: 600))],
                                                          queue: .main)
            { [weak self] in
                self?.reachMarker(.outro, at: outro)
            }
            observers.append(observer)
        }

        // 手动模式按钮轮询：任一标记存在即常挂，回调内按开关与区间决定显隐
        if activeMarkers.introSeconds != nil || activeMarkers.outroSeconds != nil {
            let interval = CMTime(seconds: Self.pollInterval, preferredTimescale: 600)
            let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                self?.handleTick(time.seconds)
            }
            observers.append(observer)
        }
        Logger.info("[introOutro] observers installed: \(observers.count) (intro=\(activeMarkers.introSeconds.map { String(format: "%.1f", $0) } ?? "nil"), outro=\(activeMarkers.outroSeconds.map { String(format: "%.1f", $0) } ?? "nil"))")

        // DASH 经资源加载器时，readyToPlay 时 duration 常为 indefinite，此时挂的边界观察者不可靠；
        // 等 duration 落定后再 refreshMarkers 重装（currentDuration>0 后可正确换算片尾并稳定触发边界）
        if currentDuration <= 0, let item = player.currentItem {
            durationToken = item.observe(\.duration, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshMarkers() }
            }
        }
    }

    private func reachMarker(_ kind: MarkerKind, at seconds: Double) {
        guard let player else { return }
        let current = player.currentTime().seconds
        Logger.info("[introOutro] boundary \(kind == .intro ? "intro" : "outro") fired at marker=\(String(format: "%.1f", seconds)) current=\(String(format: "%.1f", current)) autoEnabled=\(kind == .intro ? Settings.skipIntroAutoEnabled : Settings.skipOutroAutoEnabled) latched=\(kind == .intro ? introAutoSkipDone : outroAutoSkipDone)")
        // 拖动进度条经过标记点也会触发边界，偏离超过容差视为用户自主定位
        guard abs(current - seconds) <= Self.boundaryLeeway else { return }

        let autoEnabled = kind == .intro ? Settings.skipIntroAutoEnabled : Settings.skipOutroAutoEnabled
        let latched = kind == .intro ? introAutoSkipDone : outroAutoSkipDone
        guard autoEnabled, !latched else { return }

        skipTo(kind: kind, markerSeconds: seconds)
        if kind == .intro {
            introAutoSkipDone = true
        } else {
            outroAutoSkipDone = true
        }
        showNotify(kind.autoSkipToast)
    }

    // MARK: - 手动模式按钮（进度条上方常驻）

    /// 按钮状态机：片头标记之前 → 「跳过片头」；片尾标记之后 → 「跳过片尾」。
    /// 仅在对应自动跳过关闭时显示；同刻只挂一个按钮，离开区间自动收掉。
    private func handleTick(_ time: Double) {
        guard time.isFinite else { return }

        // 自动跳过片头：起播即跳到标记点（点开对应集直接跳过片头，不播放片头）。
        // 用轮询首帧（位置已稳定）判断，避免起播瞬间 currentTime 还在 seek 前读到 0 而误伤续播。
        if let intro = activeMarkers.introSeconds, intro > 0,
           Settings.skipIntroAutoEnabled, !introAutoSkipDone,
           time <= intro + Self.boundaryLeeway
        {
            Logger.info("[introOutro] auto-skip intro on start -> seek \(String(format: "%.1f", intro))s (current=\(String(format: "%.1f", time)))")
            skipTo(kind: .intro, markerSeconds: intro)
            introAutoSkipDone = true
            showNotify(MarkerKind.intro.autoSkipToast)
        }

        // 片尾自动跳过兜底：边界观察者在时长晚确定时可能不触发，用轮询检测"连续向前越过片尾标记点"再跳
        let previous = lastTickTime
        lastTickTime = time
        let continuous = (time - previous) > 0 && (time - previous) <= Self.pollInterval * 3
        if let outro = activeMarkers.outroSeconds, outro > 0,
           currentDuration <= 0 || outro < currentDuration,
           Settings.skipOutroAutoEnabled, !outroAutoSkipDone,
           previous < outro, time >= outro, continuous
        {
            Logger.info("[introOutro] poll-fallback skip outro at \(String(format: "%.1f", time))s")
            skipTo(kind: .outro, markerSeconds: outro)
            outroAutoSkipDone = true
            showNotify(MarkerKind.outro.autoSkipToast)
        }

        updateSkipButton(time: time)
    }

    /// 手动模式按钮（对应自动跳过关闭时）：片头标记之前显示「跳过片头」，片尾标记之后显示「跳过片尾」，
    /// 挂在传输栏 contextualActions 上（系统按钮，焦点可达可按下）；离开区间自动收掉。
    private func updateSkipButton(time: Double) {
        var wanted: UIAction?
        if !Settings.skipIntroAutoEnabled,
           let intro = activeMarkers.introSeconds, intro > 0,
           time < intro - 0.2
        {
            wanted = makeSkipAction(kind: .intro, target: intro)
        } else if !Settings.skipOutroAutoEnabled,
                  let outro = activeMarkers.outroSeconds, outro > 0,
                  currentDuration <= 0 || outro < currentDuration,
                  time >= outro
        {
            wanted = makeSkipAction(kind: .outro, target: outro)
        }

        guard let wanted else {
            clearSkipButtonIfOurs()
            return
        }
        // 已是目标按钮则不动，避免每 0.5s 重建造成 UI 抖动
        if let current = playerVC?.contextualActions, current.count == 1,
           let existing = current.first, existing.identifier == wanted.identifier
        {
            return
        }
        playerVC?.contextualActions = [wanted]
    }

    private func makeSkipAction(kind: MarkerKind, target: Double) -> UIAction {
        UIAction(title: kind.skipButtonTitle, identifier: kind.actionID) { [weak self] _ in
            guard let self, let player = self.player else { return }
            // 片头按钮显示期间用户可能已拖到标记点之后，此时按下不应把位置拉回去
            if kind == .intro, player.currentTime().seconds >= target + Self.boundaryLeeway {
                self.clearSkipButtonIfOurs()
                return
            }
            self.skipTo(kind: kind, markerSeconds: target)
            self.clearSkipButtonIfOurs()
        }
    }

    private func clearSkipButtonIfOurs() {
        guard let actions = playerVC?.contextualActions, actions.count == 1,
              let action = actions.first,
              action.identifier == Self.introActionID || action.identifier == Self.outroActionID
        else { return }
        playerVC?.contextualActions = []
    }

    private func skipTo(kind: MarkerKind, markerSeconds: Double) {
        guard let player else { return }
        let target: CMTime
        switch kind {
        case .intro:
            target = CMTime(seconds: markerSeconds + 0.5, preferredTimescale: 600)
        case .outro:
            // 跳到结尾，让连播/结束逻辑接管；优先用 item 真实片长，未知时退回 currentDuration/标记点
            let end = (player.currentItem?.duration.seconds ?? currentDuration)
            if end > 0, end.isFinite {
                target = CMTime(seconds: max(end - 0.1, 0), preferredTimescale: 600)
            } else if currentDuration > 0 {
                target = CMTime(seconds: max(currentDuration - 0.1, 0), preferredTimescale: 600)
            } else {
                target = CMTime(seconds: markerSeconds + 1, preferredTimescale: 600)
            }
        }
        Logger.info("[introOutro] skip \(kind == .intro ? "intro" : "outro") -> seek \(String(format: "%.1f", target.seconds))s")
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - 提示浮层

    private func showNotify(_ text: String) {
        guard let container else { return }
        let label: UILabel
        if let existing = notifyView {
            label = existing
        } else {
            label = UILabel()
            label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            label.textColor = .white
            label.font = .systemFont(ofSize: 26, weight: .medium)
            label.textAlignment = .center
            label.layer.cornerRadius = 10
            label.layer.masksToBounds = true
            container.addSubview(label)
            label.snp.makeConstraints { make in
                make.centerX.equalToSuperview()
                make.bottom.equalToSuperview().inset(120)
                make.width.greaterThanOrEqualTo(280)
                make.height.equalTo(60)
            }
            notifyView = label
        }
        label.text = text
        label.alpha = 1
        label.isHidden = false
        notifyTask?.cancel()
        notifyTask = Task { @MainActor [weak label] in
            try? await Task.sleep(for: .seconds(Self.notifyDuration))
            guard !Task.isCancelled else { return }
            UIView.animate(withDuration: 0.5) {
                label?.alpha = 0
            }
        }
    }
}
