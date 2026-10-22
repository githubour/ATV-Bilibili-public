//
//  SubtitlePlugin.swift
//  ATV-Bilibili
//
//  字幕选择插件: 播放器菜单列出当前视频的可用字幕轨 (含 AI 识别/翻译字幕),
//  起播时按上次选择应用偏好语言 (默认不开启字幕), 手动选择/关闭都会记住, 下个视频生效。
//  字幕轨本身由 BilibiliVideoResourceLoaderDelegate 注入 HLS 原生字幕流,
//  这里只做选中状态的切换 (AVMediaSelectionGroup)。
//

import AVFoundation
import UIKit

class SubtitlePlugin: NSObject, CommonPlayerPlugin {
    private let tracks: [SubtitleData]
    private weak var player: AVPlayer?
    /// 已自动应用过偏好的 item, 避免重复选中
    private var appliedItem: AVPlayerItem?
    /// 本次播放会话的手动选择: nil=未手动选(用全局偏好), ""=手动关闭, 其余=lan
    private var sessionLan: String?
    /// 当前选中轨道的 lan, 仅用于菜单勾选态展示
    private var currentLan: String?
    /// 最近一次菜单构建的 action 实例; transportBar 菜单不重建, 勾选态需就地更新
    private var menuActions: [(lan: String?, action: UIAction)] = []
    /// 当前选轨任务; 切换 item 时取消旧任务, 避免旧视频的字幕选择延迟落到新视频上
    private var selectionTask: Task<Void, Never>?
    /// selectionTask 对应的 item
    private var selectionItem: AVPlayerItem?

    init(tracks: [SubtitleData]) {
        self.tracks = tracks
        super.init()
    }

    func playerDidChange(player: AVPlayer) {
        self.player = player
    }

    func playerItemDidChange(playerItem: AVPlayerItem) {
        guard playerItem !== appliedItem else { return }
        currentLan = nil
        // 尽早发起字幕轨分组的异步加载, 缩短起播后字幕出现的延迟
        Task { try? await playerItem.asset.loadMediaSelectionGroup(for: .legible) }
        applyPreference(to: playerItem)
    }

    func playerDidStart(player: AVPlayer) {
        // playerItemDidChange 时字幕分组可能尚未就绪, 起播时兜底再试一次
        if let item = player.currentItem, item !== appliedItem {
            applyPreference(to: item)
        }
    }

    private func applyPreference(to item: AVPlayerItem) {
        let preferLan = Self.resolvedPreferenceLane(sessionLan: sessionLan,
                                                    autoSelect: Settings.subtitleAutoSelect,
                                                    preferLan: Settings.subtitlePreferLan)
        guard let preferLan, let track = preferredTrack(for: preferLan) else {
            // 没有可用偏好时必须**显式关闭**，不能留空 —— 留空等于把决定权交给系统，
            // 系统会按 tvOS 的字幕语言偏好挑一条（通常是英文），快进/快退触发的
            // 重新装载就会闪出字幕。
            select(lan: nil, item: item)
            return
        }
        select(lan: track.lan, item: item)
    }

    /// 本次应该选中哪条字幕轨（nil = 关闭字幕）。
    ///
    /// 抽成纯函数是有原因的：这段判断被改错过两次（快进时闪英文字幕、起播时字幕自己跳出），
    /// 而两次的坑都同源 —— 让「偏好值本身」兼任「是否要字幕」的开关。老版本把
    /// subtitlePreferLan 的默认值写成 ai-zh 并且已经落盘，而 `@UserDefault` 的 defaultValue
    /// 只对"键不存在"生效，所以只改默认值对已安装用户完全无效，旧偏好会一直赢。
    /// 这里改成只看**显式开关** autoSelect，历史遗留偏好自然失效。
    static func resolvedPreferenceLane(sessionLan: String?,
                                       autoSelect: Bool,
                                       preferLan: String) -> String?
    {
        if let sessionLan {
            // 本会话的手动选择优先："" = 已手动关闭
            return sessionLan.isEmpty ? nil : sessionLan
        }
        guard autoSelect, !preferLan.isEmpty else { return nil }
        return preferLan
    }

    /// 偏好解析: 精确匹配 lan, 否则按语言匹配 (ai-zh ↔ zh-CN 视为同语言)。
    /// 与资源加载器共用同一个解析器，避免"插件选中、清单却回空"。
    private func preferredTrack(for lan: String) -> SubtitleData? {
        guard let resolved = BilibiliVideoResourceLoaderDelegate.resolvedSubtitleLan(
            preference: lan,
            availableLans: tracks.map(\.lan)
        ) else { return nil }
        return tracks.first { $0.lan == resolved }
    }

    private func select(lan: String?, item: AVPlayerItem) {
        // 切换 item 时取消上一个选轨任务, 避免旧视频的字幕选择延迟落到新视频上
        if item !== selectionItem {
            selectionTask?.cancel()
            selectionItem = item
        }
        selectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  !group.options.isEmpty else { return }
            guard !Task.isCancelled else { return }
            // HLS NAME 即 lan_doc, 以此对应 AVMediaSelectionOption
            var option: AVMediaSelectionOption?
            if let lan {
                let name = self.tracks.first { $0.lan == lan }?.lan_doc
                option = group.options.first { $0.displayName == name }
            }
            item.select(option, in: group)
            self.appliedItem = item
            self.currentLan = option == nil ? nil : lan
            self.refreshMenuStates()
        }
    }

    /// 菜单数组不会自动重建, 选中变化后就地刷新勾选态
    private func refreshMenuStates() {
        for entry in menuActions {
            entry.action.state = entry.lan == currentLan ? .on : .off
        }
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        guard !tracks.isEmpty else { return [] }

        let offAction = UIAction(title: "关闭字幕", state: currentLan == nil ? .on : .off) { [weak self] _ in
            guard let self else { return }
            sessionLan = ""
            // 关掉就记住"不要在起播时自动挂字幕": 否则切集、以及同一 item 的重新装载
            // 都会按偏好把字幕再挂上来
            Settings.subtitleAutoSelect = false
            Settings.subtitlePreferLan = ""
            if let item = player?.currentItem {
                select(lan: nil, item: item)
            }
        }

        let trackEntries: [(lan: String?, action: UIAction)] = tracks.map { track in
            let title = track.lan.hasPrefix("ai-") ? "\(track.lan_doc)·AI" : track.lan_doc
            let action = UIAction(title: title, state: track.lan == currentLan ? .on : .off) { [weak self] _ in
                guard let self else { return }
                sessionLan = track.lan
                // 手动选轨 = 明确要字幕, 从此起播也按这条轨自动挂上
                Settings.subtitlePreferLan = track.lan
                Settings.subtitleAutoSelect = true
                if let item = player?.currentItem {
                    select(lan: track.lan, item: item)
                }
            }
            return (track.lan, action)
        }

        menuActions = [(lan: nil, action: offAction)] + trackEntries

        let menu = UIMenu(title: "字幕",
                          image: UIImage(systemName: "captions.bubble"),
                          options: [.displayInline, .singleSelection],
                          children: [offAction] + trackEntries.map(\.action))
        return [menu]
    }
}
