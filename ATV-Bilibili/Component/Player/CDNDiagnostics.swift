//
//  CDNDiagnostics.swift
//  ATV-Bilibili
//

import Alamofire
import Foundation

/// 主动实测各 CDN 候选节点的吞吐。
///
/// 用固定大小的 Range 请求实测各 CDN 候选吞吐。
/// 静态域名分级已不再承担选速职责（仅 PCDN 垫底），起播 sidx 也只验证连通性。
enum CDNDiagnostics {
    struct ProbeResult {
        let url: String
        let bytes: Int
        /// 首字节之后的传输耗时，反映纯下载速度
        let transferTime: TimeInterval
        /// DNS + 建连 + TLS + 首字节等待，跨境链路的高 RTT 主要体现在这里
        let setupTime: TimeInterval
        let error: String?

        var host: String {
            url.urlHost ?? "unknown"
        }

        var isPCDN: Bool {
            BVideoUrlUtils.isPCDN(url)
        }

        var mbps: Double? {
            guard error == nil, transferTime > 0, bytes > 0 else { return nil }
            return Double(bytes) * 8 / transferTime / 1_000_000
        }
    }

    /// 菜单手动测速 / 运行时切换：较大样本，结果更稳。
    /// 注意测速探的是文件「后段」的真实分片（见 probe），那里没有边缘缓存，
    /// 实测持续吞吐往往只有几 Mbps —— 样本再大就会把一次探测拖到十几秒，
    /// 反而在卡顿时抢走播放本身的带宽，故取 1MB。
    private static let fullProbeBytes = 1 * 1024 * 1024
    /// 起播择优：小样本，控制在几百毫秒级，不拖慢起播
    private static let quickProbeBytes = 256 * 1024

    /// 探测文件后段时所取的相对深度（0.7 = 70% 处）。
    private static let probeDepthRatio = 0.7

    private static let session: Session = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.headers = HTTPHeaders(["User-Agent": Keys.userAgent])
        return Session(configuration: config)
    }()

    private static let quickSession: Session = {
        let config = URLSessionConfiguration.ephemeral
        // 起播测速是“锦上添花”，不能让弱网把它拖成起播瓶颈
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.headers = HTTPHeaders(["User-Agent": Keys.userAgent])
        return Session(configuration: config)
    }()

    /// 逐个实测所有候选，返回原始结果供调用方自行判断（如运行时健康检测比较吞吐）。
    /// 顺序测而非并发：并发会让候选互相抢带宽导致结果失真。
    static func probeAll(urls: [String]) async -> [ProbeResult] {
        await probeAll(urls: urls, bytes: fullProbeBytes, session: session)
    }

    /// 起播用轻量测速，选出实测最快的 host；候选不足或全部失败时返回 nil。
    static func pickFastestHost(urls: [String]) async -> String? {
        guard urls.count > 1 else {
            return urls.first.flatMap { $0.urlHost }
        }
        // 候选上限 3：起播阶段不值得为第 4 个以后节点继续串行等待；
        // 菜单里的完整测速仍会用全部候选。
        let candidates = Array(urls.prefix(3))
        let results = await probeAll(urls: candidates, bytes: quickProbeBytes, session: quickSession)
        let ranked = results.sorted { ($0.mbps ?? -1) > ($1.mbps ?? -1) }
        let summary = ranked.map { r in
            let speed = r.mbps.map { String(format: "%.1fMbps", $0) } ?? "失败"
            return "\(r.host)=\(speed)"
        }.joined(separator: ", ")
        Logger.info("[cdn] 起播轻量测速 (\(quickProbeBytes / 1024)KB): \(summary)")
        return ranked.first(where: { $0.mbps != nil })?.host
    }

    /// 测速并把结果写进日志，返回适合直接显示的文本。
    static func run(urls: [String], currentHost: String?) async -> String {
        guard !urls.isEmpty else { return "无候选 CDN" }
        let results = await probeAll(urls: urls)
        let text = report(results, currentHost: currentHost, probeBytes: fullProbeBytes)
        Logger.info("\n\(text)")
        return text
    }

    private static func probeAll(urls: [String], bytes: Int, session: Session) async -> [ProbeResult] {
        var results = [ProbeResult]()
        for url in urls {
            results.append(await probe(url: url, bytes: bytes, session: session))
        }
        return results
    }

    /// 实测单个节点的持续吞吐。
    ///
    /// 关键：不测文件开头（byte 0）。B 站 m4s 的头部（ftyp+moov+sidx）是最容易被 CDN
    /// 边缘缓存的一段，读它量到的是缓存命中的瞬时爆发速度（实测同一节点能在 15~295Mbps
    /// 之间乱跳），与实际播放时下载中后段分片的持续吞吐（常常只有几 Mbps）严重背离 ——
    /// 选源/换源判据因此失真。所以先读一次头部拿到文件总长，再把采样点挪到文件后段。
    private static func probe(url: String, bytes: Int, session: Session) async -> ProbeResult {
        let headResponse = await session.request(url, headers: [
            "Range": "bytes=0-\(bytes - 1)",
            "Referer": Keys.referer,
        ]).serializingData().response

        // 总长拿不到、或文件本身很小时（后段也在缓存里），只能退回头部采样
        guard let total = totalLength(of: headResponse), total > bytes * 2 else {
            return probeResult(url: url, response: headResponse)
        }

        // 取文件 70% 深处的一段：这里是播放真正要下载的数据，没有缓存加成
        let offset = Int(Double(total) * probeDepthRatio)
        let deepResponse = await session.request(url, headers: [
            "Range": "bytes=\(offset)-\(offset + bytes - 1)",
            "Referer": Keys.referer,
        ]).serializingData().response

        return probeResult(url: url, response: deepResponse)
    }

    /// 从 206 响应的 `Content-Range`（形如 `bytes 0-1048575/123456789`）解析文件总长度
    private static func totalLength(of response: AFDataResponse<Data>) -> Int? {
        guard let contentRange = response.response?.value(forHTTPHeaderField: "Content-Range"),
              let totalPart = contentRange.split(separator: "/").last,
              let total = Int(totalPart), total > 0
        else { return nil }
        return total
    }

    private static func probeResult(url: String, response: AFDataResponse<Data>) -> ProbeResult {
        var setupTime: TimeInterval = 0
        var transferTime = response.metrics?.taskInterval.duration ?? 0
        if let metrics = response.metrics?.transactionMetrics.last,
           let fetchStart = metrics.fetchStartDate,
           let responseStart = metrics.responseStartDate,
           let responseEnd = metrics.responseEndDate
        {
            setupTime = responseStart.timeIntervalSince(fetchStart)
            transferTime = responseEnd.timeIntervalSince(responseStart)
        }

        switch response.result {
        case let .success(data):
            // 只认 206（部分内容）。若服务端忽略 Range 返回 200 整文件，用整文件字节数
            // 算出的速率会虚高到离谱，必须判为无效，不能拿去参与选源/换源。
            let status = response.response?.statusCode
            let valid = status == 206 && !data.isEmpty
            return ProbeResult(url: url, bytes: valid ? data.count : 0,
                               transferTime: transferTime, setupTime: setupTime,
                               error: valid ? nil : "非 206 响应(\(status ?? -1))")
        case let .failure(error):
            return ProbeResult(url: url, bytes: 0,
                               transferTime: transferTime, setupTime: setupTime,
                               error: error.localizedDescription)
        }
    }

    private static func report(_ results: [ProbeResult], currentHost: String?, probeBytes: Int) -> String {
        let ranked = results.sorted { ($0.mbps ?? -1) > ($1.mbps ?? -1) }
        var lines = ["CDN 实测 (\(probeBytes / 1024)KB/节点, 按实测速度排序)"]
        for (index, result) in ranked.enumerated() {
            let speed = result.mbps.map { String(format: "%.1f Mbps", $0) } ?? "失败"
            let setup = String(format: "%.0fms", result.setupTime * 1000)
            var line = "\(index + 1). \(speed)  setup \(setup)  \(result.host)"
            if result.isPCDN {
                line += "  PCDN"
            }
            if result.host == currentHost {
                line += "  <- 正在使用"
            }
            if let error = result.error {
                line += "  (\(error))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
