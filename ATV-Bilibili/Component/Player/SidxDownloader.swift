//
//  SidxDownloader.swift
//  ATV-Bilibili
//
//  sidx 索引探测与进程级 LRU 缓存。缓存键 = (流信息 + preferredHost),
//  避免把一个播放器探测出的 CDN 泄漏给另一个并发播放器。
//
//  从 BilibiliVideoResourceLoaderDelegate.swift 按职责拆出。
//

import Alamofire
import Foundation

actor SidxDownloader {
    struct SidxResult {
        let sidx: SidxParseUtil.Sidx
        let url: String
        /// 索引区间的原始字节（等价性验证的信任锚点，不参与播放数据）。
        let indexBytes: Data
    }

    /// 缓存键：流信息 + 期望 host。preferredHost 不参与判键会把一个播放器探测出的
    /// CDN 泄漏给另一个并发播放器(如画中画)，历史上因此被迫做实例级缓存
    private struct CacheKey: Hashable {
        let info: VideoPlayURLInfo.DashInfo.DashMediaInfo
        let preferredHost: String?
    }

    private enum CacheEntry {
        case inProgress(InFlight<SidxResult?, Never>)
        case ready(SidxResult)
    }

    // sidx 只有几 KB，用短超时的独立 Session，避免默认 60s 超时把起播卡死
    private static let session: Session = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        config.headers = HTTPHeaders(["User-Agent": Keys.userAgent])
        return Session(configuration: config)
    }()

    /// 进程级共享：delegate 在切画质/换源时会整体重建，实例级缓存会让同一流的 sidx 反复下载
    static let shared = SidxDownloader(maxEntries: 16)

    private let maxEntries: Int
    private var cache: [CacheKey: CacheEntry] = [:]
    private var accessOrder = LRUOrder<CacheKey>()

    init(maxEntries: Int = 16) {
        self.maxEntries = maxEntries
    }

    func sidx(from info: VideoPlayURLInfo.DashInfo.DashMediaInfo, preferredHost: String? = nil) async -> SidxResult? {
        let key = CacheKey(info: info, preferredHost: preferredHost)
        if let cached = cache[key] {
            accessOrder.touch(key)
            switch cached {
            case let .ready(sidx):
                Logger.debug("sidx cache hit \(info.id)")
                return sidx
            case let .inProgress(entry):
                Logger.debug("sidx cache wait \(info.id)")
                return await entry.task.value
            }
        }

        let entry = InFlight(task: Task<SidxResult?, Never> {
            guard !Task.isCancelled else { return nil }
            return await downloadSidx(info: info, preferredHost: preferredHost)
        })

        cache[key] = .inProgress(entry)
        accessOrder.touch(key)

        let sidx = await entry.task.value
        guard case let .inProgress(current) = cache[key],
              current.token == entry.token
        else {
            // 等待期间被 LRU 驱逐/令牌失配：缓存不再写，但**结果照常交付**——
            // 此前直接 return nil 会让调用方退化到「单大 URL 兜底清单」（无分段、无代理注册），
            // 切画质/并发流多时可构造出这次偶发退化。下载成功的结果没理由扔掉。
            Logger.debug("sidx entry evicted while in-flight \(info.id), deliver without caching")
            return sidx
        }
        if let sidx {
            cache[key] = .ready(sidx)
        } else {
            cache[key] = nil
            accessOrder.remove(key)
        }
        trimToCapacity()
        Logger.debug("get sidx \(info.id)")
        return sidx
    }

    private func elapsedMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private func trimToCapacity() {
        while cache.count > maxEntries, let oldest = accessOrder.popOldest() {
            if case let .inProgress(inFlight) = cache[oldest] {
                inFlight.task.cancel()
            }
            cache[oldest] = nil
        }
    }

    private func downloadSidx(info: VideoPlayURLInfo.DashInfo.DashMediaInfo, preferredHost: String? = nil) async -> SidxResult? {
        let range = info.segment_base.index_range
        var urls = info.playableURLs
        // sidx 只有几 KB，探测到的只是延迟不是吞吐；运行时如果发现当前 host 扛不住实际码率，
        // 由外部指定 preferredHost 时强制优先试这个 host
        if let preferredHost,
           let idx = urls.firstIndex(where: { $0.urlHost == preferredHost })
        {
            urls.insert(urls.remove(at: idx), at: 0)
        }
        for url in urls.prefix(3) {
            guard !Task.isCancelled else { return nil }
            let host = url.urlHost ?? url
            let start = Date()
            if let res = try? await Self.session.request(url,
                                                         headers: ["Range": "bytes=\(range)",
                                                                   "Referer": "https://www.bilibili.com/"])
                .serializingData().result.get(),
                !Task.isCancelled,
                let segment = SidxParseUtil.processIndexData(data: res),
                !segment.segments.isEmpty
            {
                Logger.info("sidx ok in \(elapsedMs(since: start))ms from \(host)")
                return SidxResult(sidx: segment, url: url, indexBytes: res)
            }
            Logger.warn("sidx download failed in \(elapsedMs(since: start))ms on \(host), try next url")
        }
        return nil
    }
}
