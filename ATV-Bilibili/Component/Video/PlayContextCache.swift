//
//  PlayContextCache.swift
//  ATV-Bilibili
//
//  Created by OpenAI on 2026/4/4.
//

import Foundation

struct PlayContextKey: Hashable {
    let aid: Int
    let cid: Int
    let epid: Int
    let seasonId: Int
}

struct PlayContextSnapshot {
    let cid: Int
    let playerInfo: PlayerInfo?
    let videoPlayURLInfo: VideoPlayURLInfo
    var detail: VideoDetail?
    /// playurl 带时效签名，缓存不能无限期复用
    var createdAt: Date = .init()

    /// 超过有效期即按 miss 处理，由调用方重新取流
    func isStale(now: Date, maxAge: TimeInterval) -> Bool {
        now.timeIntervalSince(createdAt) > maxAge
    }
}

enum PlayContextMode: String, Hashable {
    case preview
    case regular

    var includeDetail: Bool {
        switch self {
        case .preview:
            return false
        case .regular:
            return true
        }
    }

    var requestOptions: PlayURLRequestOptions {
        switch self {
        case .preview:
            return .featuredPreview
        case .regular:
            return .regular
        }
    }
}

private struct PlayContextEntryKey: Hashable {
    let contextKey: PlayContextKey
    let mode: PlayContextMode
}

actor PlayContextCache {
    private let maxEntries = 12
    private let recentEntriesToKeep = 4
    /// 签名 URL 的保守有效期；过期后重新请求，避免回看时播放失败
    private let maxAge: TimeInterval = 20 * 60
    private var entries = [PlayContextEntryKey: PlayContextSnapshot]()
    private var inFlightTasks = [PlayContextEntryKey: InFlight<PlayContextSnapshot, Error>]()
    private var accessOrder = LRUOrder<PlayContextEntryKey>()
    /// detail 补拉的去重登记：命中缓存但缺 detail 的并发调用者（预热与正式装配）
    /// 只发一次请求——与主 flow 的 inFlightTasks 同思路，此前每个等待者各拉一次
    private var detailFetches = [Int: InFlight<VideoDetail?, Error>]()

    private func ensureDetail(aid: Int) async -> VideoDetail? {
        if let entry = detailFetches[aid] {
            return try? await entry.task.value
        }
        let entry = InFlight(task: Task<VideoDetail?, Error> {
            try await WebRequest.requestDetailVideo(aid: aid)
        })
        detailFetches[aid] = entry
        let result = try? await entry.task.value
        // 完成后清掉登记：detail 会随互动/编辑变化，不留作长期缓存
        if let current = detailFetches[aid], current.token == entry.token {
            detailFetches[aid] = nil
        }
        return result
    }

    func preload(playInfo: PlayInfo, mode: PlayContextMode) async {
        _ = try? await context(for: playInfo, mode: mode)
    }

    func context(for playInfo: PlayInfo, mode: PlayContextMode) async throws -> PlayContextSnapshot {
        let resolvedPlayInfo = try await PlayInfoResolver.resolve(playInfo)
        let entryKey = PlayContextEntryKey(contextKey: resolvedPlayInfo.contextKey, mode: mode)

        if var cached = entries[entryKey] {
            if cached.isStale(now: Date(), maxAge: maxAge) {
                // 过期条目按 miss 处理，重新拉 playurl
                entries[entryKey] = nil
            } else {
                accessOrder.touch(entryKey)
                if mode.includeDetail, cached.detail == nil {
                    cached.detail = await ensureDetail(aid: resolvedPlayInfo.aid)
                    entries[entryKey] = cached
                }
                return cached
            }
        }

        if let entry = inFlightTasks[entryKey] {
            var snapshot = try await entry.task.value
            accessOrder.touch(entryKey)
            if mode.includeDetail, snapshot.detail == nil {
                snapshot.detail = await ensureDetail(aid: resolvedPlayInfo.aid)
                entries[entryKey] = snapshot
            }
            return snapshot
        }

        let entry = InFlight(task: Task<PlayContextSnapshot, Error> {
            try Task.checkCancellation()
            async let playerInfoReq = try? WebRequest.requestPlayerInfo(aid: resolvedPlayInfo.aid, cid: resolvedPlayInfo.cid ?? 0)
            async let detailReq = mode.includeDetail ? (try? WebRequest.requestDetailVideo(aid: resolvedPlayInfo.aid)) : nil

            let playURLInfo: VideoPlayURLInfo
            if resolvedPlayInfo.isBangumi {
                playURLInfo = try await WebRequest.requestPcgPlayUrl(aid: resolvedPlayInfo.aid,
                                                                     cid: resolvedPlayInfo.cid ?? 0,
                                                                     options: mode.requestOptions)
            } else {
                playURLInfo = try await WebRequest.requestPlayUrl(aid: resolvedPlayInfo.aid,
                                                                  cid: resolvedPlayInfo.cid ?? 0,
                                                                  options: mode.requestOptions)
            }
            try Task.checkCancellation()

            return PlayContextSnapshot(cid: resolvedPlayInfo.cid ?? 0,
                                       playerInfo: await playerInfoReq,
                                       videoPlayURLInfo: playURLInfo,
                                       detail: await detailReq)
        })

        inFlightTasks[entryKey] = entry
        return try await resolve(entry, for: entryKey)
    }

    func trim(keeping playInfos: [PlayInfo]) {
        let baseKeysToKeep = Set(playInfos.compactMap { info -> PlayContextKey? in
            guard let cid = info.cid, cid > 0 else { return nil }
            return PlayContextKey(aid: info.aid,
                                  cid: cid,
                                  epid: info.epid ?? 0,
                                  seasonId: info.seasonId ?? 0)
        })
        let recentKeys = accessOrder.mostRecent(recentEntriesToKeep)
        let entryKeysToKeep = Set((Array(entries.keys) + Array(inFlightTasks.keys)).filter {
            baseKeysToKeep.contains($0.contextKey)
        } + recentKeys)
        for key in inFlightTasks.keys.filter({ !entryKeysToKeep.contains($0) }) {
            inFlightTasks[key]?.task.cancel()
            inFlightTasks[key] = nil
        }
        entries = entries.filter { entryKeysToKeep.contains($0.key) }
        accessOrder.keep(only: entryKeysToKeep)
    }

    private func resolve(_ entry: InFlight<PlayContextSnapshot, Error>, for key: PlayContextEntryKey) async throws -> PlayContextSnapshot {
        do {
            let snapshot = try await entry.task.value
            guard inFlightTasks[key]?.token == entry.token else {
                throw CancellationError()
            }
            inFlightTasks[key] = nil
            entries[key] = snapshot
            accessOrder.touch(key)
            trimToMaxEntryCount()
            return snapshot
        } catch {
            if inFlightTasks[key]?.token == entry.token {
                inFlightTasks[key] = nil
            }
            throw error
        }
    }

    private func trimToMaxEntryCount() {
        guard entries.count > maxEntries else { return }
        while entries.count > maxEntries, let key = accessOrder.popOldest() {
            entries[key] = nil
        }
    }
}
