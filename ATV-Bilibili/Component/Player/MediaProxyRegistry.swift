//
//  MediaProxyRegistry.swift
//  ATV-Bilibili
//
//  当前播放会话内的媒体代理注册表（同步线程安全）。
//  媒体 ID 映射到当前会话已注册的媒体流及其 CDN 候选；不接受外部 URL，不跨会话共享。
//

import Foundation

/// 当前播放会话内的媒体代理注册表（同步线程安全）。
/// 媒体 ID 映射到当前会话已注册的媒体流及其 CDN 候选；不接受外部 URL，不跨会话共享。
/// 对外只提供不可变的元信息快照：totalLength 的写入（锁内）与读取（快照拷贝）
/// 不会竞争；downloader 自身是 actor，跨线程引用安全。
final class MediaProxyRegistry: @unchecked Sendable {
    /// 不可变的单次请求视图。downloader 为 actor 引用，可在 handler 线程使用；
    /// totalLength/candidates 为读取时刻的拷贝。
    struct MediaSnapshot {
        let candidates: [String]
        let referer: String
        let downloader: MediaRangeDownloader
        let totalLength: Int64?
    }

    private final class Entry {
        let candidates: [String]
        let referer: String
        let downloader: MediaRangeDownloader
        var totalLength: Int64?
        init(candidates: [String], referer: String, downloader: MediaRangeDownloader) {
            self.candidates = candidates
            self.referer = referer
            self.downloader = downloader
        }

        func snapshot() -> MediaSnapshot {
            MediaSnapshot(candidates: candidates, referer: referer,
                          downloader: downloader, totalLength: totalLength)
        }
    }

    private let lock = NSLock()
    private var entries = [String: Entry]()
    private var idByMedia = [VideoPlayURLInfo.DashInfo.DashMediaInfo: String]()

    func register(media: VideoPlayURLInfo.DashInfo.DashMediaInfo, candidates: [String], referer: String, downloader: MediaRangeDownloader) {
        lock.lock()
        defer { lock.unlock() }
        if idByMedia[media] != nil { return }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        idByMedia[media] = id
        entries[id] = Entry(candidates: candidates, referer: referer, downloader: downloader)
    }

    func id(for media: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return idByMedia[media]
    }

    /// 锁内一次性拷贝，后续读取不再触碰共享可变状态。
    func snapshot(for id: String) -> MediaSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.snapshot()
    }

    /// 取指定媒体的下载器引用（actor，跨线程使用安全），用于设置信任锚点等。
    func downloader(for media: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> MediaRangeDownloader? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = idByMedia[media] else { return nil }
        return entries[id]?.downloader
    }

    func updateTotalLength(_ total: Int64, for id: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[id]?.totalLength = total
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        idByMedia.removeAll()
        lock.unlock()
    }
}
