//
//  BVideoQualityPlugin.swift
//  ATV-Bilibili
//

import AVKit

class BVideoQualityPlugin: NSObject, CommonPlayerPlugin {
    private weak var playerVC: AVPlayerViewController?
    private weak var player: AVPlayer?
    private let playData: PlayerDetailData
    private var availableQualities: [QualityOption] = []
    private var currentQualityId: Int?
    private var currentStreamIndex: Int? // 当前选中的流索引
    private var isQualityLocked: Bool = false // 是否手动锁定了画质
    /// 返回是否真正切换成功；失败时不更新勾选态，避免菜单与画面不一致
    private var onQualityChange: ((Int, Int?) async -> Bool)? // (qualityId, streamIndex)
    /// 未手动锁定时, 从 accessLog 探测到的 ABR 实际播放流
    private var abrStreamIndex: Int?
    /// 菜单 action 实例(按 streamIndex 索引), transportBar 菜单不重建, 勾选态就地更新
    private var menuStreamActions: [Int: UIAction] = [:]
    private var timeObserver: Any?

    struct QualityOption {
        let id: Int
        let name: String
        let description: String
        let bandwidth: Int // 该流的码率（bps）
        let codec: String // 编码格式（如 avc1, hev1）
        let streamIndex: Int? // 在 dash.video 数组中的索引（用于精确定位流）
    }

    init(detailData: PlayerDetailData, onQualityChange: @escaping (Int, Int?) async -> Bool) {
        playData = detailData
        self.onQualityChange = onQualityChange
        super.init()

        // 从 VideoPlayURLInfo 中提取可用画质
        extractAvailableQualities()
    }

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
    }

    func playerDidChange(player: AVPlayer) {
        // 清理旧 player 上的观察者(必须用旧 player 移除)
        if let timeObserver, let current = self.player {
            current.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        self.player = player
        abrStreamIndex = nil
    }

    func playerWillStart(player: AVPlayer) {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        // 周期探测 ABR 实际播放的流, 用于菜单勾选当前画质。
        // 主队列：pollAbrQuality 会读 isQualityLocked/player，这些由主线程菜单动作改写。
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1),
                                                      queue: .main)
        { [weak self] _ in
            guard let self else { return }
            self.pollAbrQuality()
        }
    }

    func playerDidCleanUp(player: AVPlayer) {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        self.player = nil
    }

    /// 当前实际播放的流: 手动锁定 > ABR 探测 > 默认起播流(最高画质 + AVC 优先) > 接口返回的画质
    private var effectiveStreamIndex: Int? {
        if isQualityLocked { return currentStreamIndex }
        if let abrStreamIndex { return abrStreamIndex }
        if let defaultStreamIndex { return defaultStreamIndex }
        if let currentQualityId {
            return availableQualities.first { $0.id == currentQualityId }?.streamIndex
        }
        return nil
    }

    /// 默认起播流在 dash.video 中的下标, 与资源加载器 BVideoStreamSelection 的选择保持一致
    private var defaultStreamIndex: Int? {
        let streams = playData.videoPlayURLInfo.dash.video
        guard let best = BVideoStreamSelection.defaultStream(from: streams) else { return nil }
        return streams.firstIndex { $0.id == best.id && $0.codecs == best.codecs && $0.bandwidth == best.bandwidth }
    }

    private func pollAbrQuality() {
        guard !isQualityLocked,
              let events = player?.currentItem?.accessLog()?.events,
              let last = events.last,
              last.indicatedBitrate > 0,
              let matched = nearestStream(forIndicatedBitrate: last.indicatedBitrate),
              let matchedIndex = matched.streamIndex,
              matchedIndex != abrStreamIndex
        else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.abrStreamIndex = matchedIndex
            self.refreshMenuStates()
        }
    }

    /// accessLog 的 indicatedBitrate 对应播放列表声明的 BANDWIDTH(平均码率×1.5 峰值, 见 peakBandwidth)
    private func nearestStream(forIndicatedBitrate bitrate: Double) -> QualityOption? {
        availableQualities.min {
            // 峰值带宽系数与播放列表声明同源（loader.peakBandwidth），两处必须永远一致
            abs(Double(BilibiliVideoResourceLoaderDelegate.peakBandwidth(forAverage: $0.bandwidth)) - bitrate)
                < abs(Double(BilibiliVideoResourceLoaderDelegate.peakBandwidth(forAverage: $1.bandwidth)) - bitrate)
        }
    }

    private func refreshMenuStates() {
        guard let effective = effectiveStreamIndex else { return }
        for (streamIndex, action) in menuStreamActions {
            action.state = streamIndex == effective ? .on : .off
        }
    }

    private func extractAvailableQualities() {
        let supportFormats = playData.videoPlayURLInfo.support_formats
        let videoStreams = playData.videoPlayURLInfo.dash.video

        // 为每个视频流创建一个 QualityOption
        availableQualities = videoStreams.enumerated().map { index, stream in
            // 尝试从 support_formats 中找到该画质的描述信息
            let format = supportFormats.first { $0.quality == stream.id }
            let baseName = format?.new_description ?? "画质 \(stream.id)"

            // 提取编码类型（avc1 -> AVC, hev1 -> HEVC）
            let codecType: String
            if stream.codecs.starts(with: "avc") {
                codecType = "AVC"
            } else if stream.codecs.starts(with: "hev") || stream.codecs.starts(with: "hvc") {
                codecType = "HEVC"
            } else {
                codecType = String(stream.codecs.prefix(4))
            }

            // 构建完整的名称：画质名称 (编码, 码率)
            let mbps = Double(stream.bandwidth) / 1_000_000.0
            let fullName = String(format: "%@ (%@, %.1f Mbps)", baseName, codecType, mbps)

            return QualityOption(
                id: stream.id,
                name: fullName,
                description: format?.display_desc ?? "",
                bandwidth: stream.bandwidth,
                codec: stream.codecs,
                streamIndex: index
            )
        }

        // 按画质 ID 降序排序，同画质按码率降序排序
        availableQualities.sort {
            if $0.id != $1.id {
                return $0.id > $1.id
            } else {
                return $0.bandwidth > $1.bandwidth
            }
        }

        // 设置当前画质为实际返回的画质
        currentQualityId = playData.videoPlayURLInfo.quality
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        guard !availableQualities.isEmpty else { return [] }

        menuStreamActions.removeAll()
        let qualityImage = UIImage(systemName: "video.fill")

        // 按画质 ID 分组
        let groupedQualities = Dictionary(grouping: availableQualities, by: { $0.id })

        // 获取所有唯一的画质 ID 并排序
        let sortedQualityIds = groupedQualities.keys.sorted(by: >)

        // 为每个画质创建子菜单
        let qualitySubmenus = sortedQualityIds.map { qualityId -> UIMenu in
            let streams = groupedQualities[qualityId]!

            // 获取画质的基础名称（去掉编码和码率信息）
            let baseName: String
            if let firstStream = streams.first {
                baseName = Self.baseName(of: firstStream.name)
            } else {
                baseName = "画质 \(qualityId)"
            }

            // 为该画质下的每个流创建菜单项
            let streamActions = streams.map { quality -> UIAction in
                // 是否为当前实际播放的流(手动锁定/ABR探测/接口返回)
                let isCurrentStream = quality.streamIndex == effectiveStreamIndex

                // 提取编码和码率信息（如 "AVC, 27.2 Mbps"）
                let streamInfo: String
                if let range = quality.name.range(of: " (") {
                    let infoWithParens = String(quality.name[range.lowerBound...])
                    streamInfo = infoWithParens.trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
                } else {
                    let mbps = Double(quality.bandwidth) / 1_000_000.0
                    streamInfo = String(format: "%.1f Mbps", mbps)
                }

                let action = UIAction(
                    title: streamInfo,
                    state: isCurrentStream ? .on : .off
                ) { [weak self] _ in
                    self?.switchQuality(to: quality)
                }
                if let streamIndex = quality.streamIndex {
                    menuStreamActions[streamIndex] = action
                }
                return action
            }

            // 如果只有一个流，显示完整信息
            let menuTitle: String
            if streams.count == 1, let stream = streams.first {
                let mbps = Double(stream.bandwidth) / 1_000_000.0
                menuTitle = String(format: "%@ (%.1f Mbps)", baseName, mbps)
            } else {
                menuTitle = baseName
            }

            return UIMenu(
                title: menuTitle,
                options: streams.count == 1 ? [] : [.displayInline],
                children: streamActions
            )
        }

        // 顶级标题带上当前画质, 不用进子菜单就能看到正在播放哪一档
        let qualityMenuTitle: String
        if let effective = effectiveStreamIndex,
           let current = availableQualities.first(where: { $0.streamIndex == effective })
        {
            qualityMenuTitle = "画质·\(Self.baseName(of: current.name))"
        } else {
            qualityMenuTitle = "画质"
        }

        let qualityMenu = UIMenu(
            title: qualityMenuTitle,
            image: qualityImage,
            identifier: UIMenu.Identifier(rawValue: "quality"),
            children: qualitySubmenus
        )

        return [qualityMenu]
    }

    /// 提取画质基础名称（如 "4K 超高清 (AVC, 27.2 Mbps)" -> "4K 超高清"）
    private static func baseName(of name: String) -> String {
        if let range = name.range(of: " (") {
            return String(name[..<range.lowerBound])
        }
        return name
    }

    private func switchQuality(to quality: QualityOption) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let switched = await self.onQualityChange?(quality.id, quality.streamIndex) ?? false
            guard switched else { return }
            // 只有播放器真的重建成功后才更新勾选态
            self.isQualityLocked = true
            self.currentQualityId = quality.id
            self.currentStreamIndex = quality.streamIndex
            self.refreshMenuStates()
        }
    }
}
