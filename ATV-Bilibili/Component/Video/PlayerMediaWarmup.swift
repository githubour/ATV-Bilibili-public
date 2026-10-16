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
                        preferredHost: String? = nil) async throws -> PreparedPlayerMedia
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
                             preferredHost: preferredHost)
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
    private var inFlight = [String: InFlight<PreparedPlayerMedia, Error>]()
    private var accessOrder = LRUOrder<String>()
    private var cancellationGeneration = 0

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
        let key = resolvedPlayInfo.sequenceKey
        if let cached = prepared[key] {
            accessOrder.touch(key)
            return cached
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
                playerInfo: snapshot.playerInfo
            )
        })

        inFlight[key] = entry
        return try await resolve(entry, for: key)
    }

    private func resolve(_ entry: InFlight<PreparedPlayerMedia, Error>, for key: String) async throws -> PreparedPlayerMedia {
        do {
            let media = try await entry.task.value
            if let cached = prepared[key] {
                accessOrder.touch(key)
                return cached
            }
            guard inFlight[key]?.token == entry.token else {
                throw CancellationError()
            }
            inFlight[key] = nil
            prepared[key] = media
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
        accessOrder.clear()
    }

    private func trimToCapacity() {
        while prepared.count > maxPreparedEntries, let key = accessOrder.popOldest() {
            prepared[key] = nil
        }
    }
}
