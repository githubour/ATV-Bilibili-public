//
//  PlayerMediaWarmup.swift
//  ATV-Bilibili
//
//  Created by OpenAI on 2026/4/4.
//

import AVFoundation
import Foundation

final class PreparedPlayerMedia: @unchecked Sendable {
    let asset: AVURLAsset
    let delegate: BilibiliVideoResourceLoaderDelegate

    init(asset: AVURLAsset, delegate: BilibiliVideoResourceLoaderDelegate) {
        self.asset = asset
        self.delegate = delegate
    }
}

enum PlayerMediaFactory {
    static func prepare(aid: Int,
                        urlInfo: VideoPlayURLInfo,
                        playerInfo: PlayerInfo?,
                        maxQuality: Int? = nil,
                        streamIndex: Int? = nil,
                        preferredHost: String? = nil,
                        transportMode: MediaTransportMode = .direct) async throws -> PreparedPlayerMedia
    {
        let playURL = URL(string: BilibiliVideoResourceLoaderDelegate.URLs.play)!
        let headers: [String: String] = [
            "User-Agent": Keys.userAgent,
            "Referer": Keys.referer(for: aid),
        ]
        let asset = AVURLAsset(url: playURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let delegate = BilibiliVideoResourceLoaderDelegate()
        delegate.setBilibili(info: urlInfo,
                             subtitles: playerInfo?.subtitle?.subtitles ?? [],
                             aid: aid,
                             maxQuality: maxQuality,
                             streamIndex: streamIndex,
                             preferredHost: preferredHost,
                             transportMode: transportMode)
        asset.resourceLoader.setDelegate(delegate, queue: DispatchQueue(label: "loader.\(aid).\(UUID().uuidString)"))
        try Task.checkCancellation()
        let playable = try await asset.load(.isPlayable)
        try Task.checkCancellation()
        guard playable else {
            throw "加载资源失败"
        }
        // sidx 缓存进程级共享，不做整表取消；在途探测最多几 KB，让其自然完成入库
        await delegate.prewarmPrimaryVideoIndex()
        try Task.checkCancellation()
        return PreparedPlayerMedia(asset: asset, delegate: delegate)
    }
}

actor PlayerMediaWarmupManager {
    private let maxPreparedEntries = 4
    private let playContextCache: PlayContextCache
    private var prepared = [String: PreparedPlayerMedia]()
    private var preparedAt = [String: Date]()
    private var inFlight = [String: InFlight<PreparedPlayerMedia, Error>]()
    private var accessOrder = LRUOrder<String>()
    private var cancellationGeneration = 0
    /// 预热资源同样持有带时效的 playurl，不能只靠 LRU 无限期复用
    private let maxPreparedAge: TimeInterval = 20 * 60

    init(playContextCache: PlayContextCache) {
        self.playContextCache = playContextCache
    }

    func preload(playInfo: PlayInfo) async {
        _ = try? await preparedMedia(for: playInfo)
    }

    func preparedMedia(for playInfo: PlayInfo) async throws -> PreparedPlayerMedia {
        let generation = cancellationGeneration
        let resolvedPlayInfo = try await PlayInfoResolver.resolve(playInfo)
        try Task.checkCancellation()
        guard cancellationGeneration == generation else { throw CancellationError() }
        // 传输模式纳入缓存身份：直连与代理资源不得复用。创建任务时固定快照，
        // 开关只影响新建会话，已准备的旧模式资产保持原生命周期。
        let transportSnapshot: MediaTransportMode = Settings.multiCDNEnabled ? .accelerated : .direct
        let key = resolvedPlayInfo.sequenceKey + "#" + transportCacheKey(for: transportSnapshot)
        if let cached = prepared[key], isFreshPrepared(key) {
            accessOrder.touch(key)
            return cached
        } else if prepared[key] != nil {
            prepared[key] = nil
            preparedAt[key] = nil
        }
        if let entry = inFlight[key] {
            return try await resolve(entry, for: key)
        }

        let entry = InFlight(task: Task<PreparedPlayerMedia, Error> {
            try Task.checkCancellation()
            let snapshot = try await playContextCache.context(for: resolvedPlayInfo, mode: .regular)
            try Task.checkCancellation()
            return try await PlayerMediaFactory.prepare(
                aid: resolvedPlayInfo.aid,
                urlInfo: snapshot.videoPlayURLInfo,
                playerInfo: snapshot.playerInfo,
                transportMode: transportSnapshot
            )
        })

        inFlight[key] = entry
        return try await resolve(entry, for: key)
    }

    private func resolve(_ entry: InFlight<PreparedPlayerMedia, Error>, for key: String) async throws -> PreparedPlayerMedia {
        do {
            let media = try await entry.task.value
            if let cached = prepared[key], isFreshPrepared(key) {
                accessOrder.touch(key)
                return cached
            }
            guard inFlight[key]?.token == entry.token else {
                throw CancellationError()
            }
            inFlight[key] = nil
            prepared[key] = media
            preparedAt[key] = Date()
            accessOrder.touch(key)
            trimToCapacity()
            return media
        } catch {
            if inFlight[key]?.token == entry.token {
                inFlight[key] = nil
            }
            throw error
        }
    }

    func cancelAll() {
        cancellationGeneration += 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        prepared.removeAll()
        preparedAt.removeAll()
        accessOrder.clear()
    }

    /// 预热资产同样持有带时效的 playurl：无时间戳或超龄即视为未准备
    private func isFreshPrepared(_ key: String) -> Bool {
        guard let at = preparedAt[key] else { return false }
        return Date().timeIntervalSince(at) <= maxPreparedAge
    }

    private func transportCacheKey(for mode: MediaTransportMode) -> String {
        switch mode {
        case .direct: return "direct"
        case .proxy: return "proxy"
        case .accelerated: return "accel"
        }
    }

    private func trimToCapacity() {
        while prepared.count > maxPreparedEntries, let key = accessOrder.popOldest() {
            prepared[key] = nil
            preparedAt[key] = nil
        }
    }
}
