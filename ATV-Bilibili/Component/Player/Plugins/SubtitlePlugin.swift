//
//  SubtitlePlugin.swift
//  ATV-Bilibili
//
//  字幕选择插件: 播放器菜单列出当前视频的可用字幕轨 (含 AI 识别/翻译字幕),
//  起播时自动开启偏好语言 (默认 AI 中文), 手动选择会记住偏好, 下个视频生效。
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
        let preferLan: String
        if let sessionLan {
            if sessionLan.isEmpty {
                // 本会话已手动关闭: 显式取消选中, 确保切集后也不残留字幕
                select(lan: nil, persist: false, item: item)
                return
            }
            preferLan = sessionLan
        } else {
            preferLan = Settings.subtitlePreferLan
        }
        guard let track = preferredTrack(for: preferLan) else {
            // 偏好语言没有对应轨道时（例如【人民的名义】这类只有 AI 英/日文翻译轨的稿件）
            // 必须**显式关闭**，不能留空：留空等于把决定权交给系统，系统会按 tvOS 的
            // 字幕语言偏好挑一条（通常是英文），快进/快退触发的重新装载会让它闪一下。
            select(lan: nil, persist: false, item: item)
            return
        }
        select(lan: track.lan, persist: false, item: item)
    }

    /// 偏好解析: 精确匹配 lan, 否则按语言匹配 (ai-zh ↔ zh-CN 视为同语言)
    private func preferredTrack(for lan: String) -> SubtitleData? {
        if let exact = tracks.first(where: { $0.lan == lan }) { return exact }
        let base = Self.baseLanguage(of: lan)
        guard !base.isEmpty else { return nil }
        return tracks.first { Self.baseLanguage(of: $0.lan) == base }
    }

    private static func baseLanguage(of lan: String) -> String {
        var l = lan
        if l.hasPrefix("ai-") { l = String(l.dropFirst(3)) }
        return String(l.split(separator: "-").first ?? "")
    }

    private func select(lan: String?, persist: Bool, item: AVPlayerItem) {
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
            if option != nil, persist, let lan {
                Settings.subtitlePreferLan = lan
            }
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
            if let item = player?.currentItem {
                select(lan: nil, persist: false, item: item)
            }
        }

        let trackEntries: [(lan: String?, action: UIAction)] = tracks.map { track in
            let title = track.lan.hasPrefix("ai-") ? "\(track.lan_doc)·AI" : track.lan_doc
            let action = UIAction(title: title, state: track.lan == currentLan ? .on : .off) { [weak self] _ in
                guard let self else { return }
                sessionLan = track.lan
                if let item = player?.currentItem {
                    select(lan: track.lan, persist: true, item: item)
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
