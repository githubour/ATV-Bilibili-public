//
//  MediaRangeDownloader+Transport.swift
//  ATV-Bilibili
//
//  单次 Range 尝试: 全局预算等待、Session 复用、Content-Range 严格校验、
//  逐字节读取与吞吐实测、失败分类与 host 隔离记账。
//
//  从 MediaRangeDownloader.swift 按职责拆出。actor 的存储状态仍在主文件,
//  因此这些方法改为模块内可见(原为 private), 语义不变。
//

import Foundation

extension MediaRangeDownloader {
    /// 读流时先攒块再入 Data 的块大小（与 iOS 侧同名常量保持一致）。
    private static let transferChunkBytes = 64 * 1024

    // MARK: 单次尝试（含严格校验）

    func fetchAttempt(subrange: MediaByteRange, urlString: String, host: String) async throws -> Data {
        try Task.checkCancellation()
        // 全局预算：许可 token 一一绑定，defer 恰好释放一次。
        // 有界等待超时直接抛 budgetExhausted，绝不无许可发送。
        let permit: BudgetPermit
        if let acquired = await MediaDownloadBudget.shared.tryAcquireNow(host: host) {
            permit = acquired
        } else {
            permit = try await waitForBudget(host: host)
        }
        // 诊断用实际在途 host 计数（与累计统计区分），退出时配对扣减
        activeHostCounts[host, default: 0] += 1
        defer {
            if let current = self.activeHostCounts[host] {
                self.activeHostCounts[host] = current > 1 ? current - 1 : nil
            }
            let permit = permit
            Task { await MediaDownloadBudget.shared.release(permit) }
        }

        let session = ensureSession()
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=\(subrange.start)-\(subrange.end)", forHTTPHeaderField: "Range")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let startDate = Date()
        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (asyncBytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            await recordFailure(host: host, category: classify(error: error, status: nil))
            throw error
        }
        // TTFB：首字节（响应头）到达耗时
        let ttfb = Date().timeIntervalSince(startDate)
        guard let http = response as? HTTPURLResponse else {
            await recordFailure(host: host, category: .network(NSError(domain: "cdn", code: -1)))
            throw MediaRangeError.upstream(status: -1)
        }
        // 取消不计入失败：调用方已取消时直接退出
        if Task.isCancelled {
            throw CancellationError()
        }
        guard http.statusCode == 206 else {
            await recordFailure(host: host, category: classify(error: nil, status: http.statusCode))
            if http.statusCode == 403 || http.statusCode == 404 || http.statusCode == 416 {
                // 403/404/416 分类，避免无限重复同一无效候选
                await isolateSingle(host: host)
            }
            throw MediaRangeError.upstream(status: http.statusCode)
        }
        // Content-Range 校验
        guard let contentRangeValue = http.value(forHTTPHeaderField: "Content-Range"),
              let parsed = MediaRangeParsing.parseContentRange(contentRangeValue)
        else {
            // 200 或缺失 Content-Range：拒绝不正确响应，不交付
            await recordFailure(host: host, category: .mismatch)
            throw MediaRangeError.mismatch
        }
        guard parsed.range == subrange else {
            await recordFailure(host: host, category: .mismatch)
            await isolateSingle(host: host)
            throw MediaRangeError.mismatch
        }
        if let total = parsed.total {
            if let known = knownTotalLength, known != total {
                await recordFailure(host: host, category: .mismatch)
                await isolateSingle(host: host)
                throw MediaRangeError.mismatch
            }
            knownTotalLength = total
            // 区间不得超出总长
            if subrange.end >= total {
                await recordFailure(host: host, category: .mismatch)
                throw MediaRangeError.unsatisfiable(total: total)
            }
        }
        // 逐字节读取，测量有效吞吐；重复下载字节不计入有效吞吐由上层 extraBytes 区分
        var data = Data()
        data.reserveCapacity(Int(subrange.length))
        do {
            // AsyncBytes 只能逐字节产出, 但不必逐字节 append: 先攒满 64KiB 再整块拷进 Data,
            // 把每字节一次的内存增长/边界检查降成每块一次（与 iOS 侧实现一致）。
            // （试过 chunks(ofCount:)，本 SDK 的 AsyncBytes 无此成员；换 data(for:) 整块拉取
            //   会破坏 TTFB 语义，故维持逐字节流 + 64KiB 攒块。2026-11-14）
            var chunk = [UInt8]()
            chunk.reserveCapacity(Self.transferChunkBytes)
            for try await byte in asyncBytes {
                chunk.append(byte)
                guard chunk.count == Self.transferChunkBytes else { continue }
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                // 取消检查按 64KiB 降频：512KiB 子区间从 52 万次原子读降到 8 次；
                // 真取消信号最坏延迟一个 64KiB 块，对流式下载无感知（审核 2026-10-20 问题 11①）
                if Task.isCancelled {
                    throw CancellationError()
                }
                // 背压：单个子区间在内存中完整组装（已受 subrangeMaxBytes 与
                // singleRequestMemoryCap 约束），此处不做额外限流
                if Int64(data.count) > subrange.length {
                    await recordFailure(host: host, category: .mismatch)
                    throw MediaRangeError.mismatch
                }
            }
            if !chunk.isEmpty {
                data.append(contentsOf: chunk)
                if Int64(data.count) > subrange.length {
                    await recordFailure(host: host, category: .mismatch)
                    throw MediaRangeError.mismatch
                }
            }
        } catch is CancellationError {
            // 被取消前已传输的字节计入 extra（上游流量真实发生但未交付），
            // 保证诊断的冗余比例可信；取消本身不计入 CDN 健康失败。
            addExtra(Int64(data.count))
            throw CancellationError()
        } catch {
            // 传输中断前已读取的部分同样计入 extra（未交付的上游流量）
            addExtra(Int64(data.count))
            await recordFailure(host: host, category: .truncated)
            throw MediaRangeError.truncated
        }
        // 实际数据长度校验
        guard Int64(data.count) == subrange.length else {
            await recordFailure(host: host, category: .truncated)
            throw MediaRangeError.truncated
        }
        let transferTime = Date().timeIntervalSince(startDate)
        await recordSuccess(host: host, bytes: Int64(data.count), ttfb: ttfb, transferTime: transferTime)
        return data
    }

    /// 有界等待预算许可。超时不再无许可通行，而是抛 budgetExhausted，
    /// 由上层按失败传播（播放器级恢复做有预算的降级），并保持 release 配对。
    func waitForBudget(host: String) async throws -> BudgetPermit {
        // 有界等待：最多 10s，每 50ms 重试一次，可取消
        let deadline = Date().addingTimeInterval(10)
        while true {
            try Task.checkCancellation()
            if let permit = await MediaDownloadBudget.shared.tryAcquireNow(host: host) {
                return permit
            }
            if Date() > deadline {
                throw MediaRangeError.budgetExhausted
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func ensureSession() -> URLSession {
        if let session { return session }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let created = URLSession(configuration: config)
        session = created
        return created
    }

    func recordSuccess(host: String, bytes: Int64, ttfb: TimeInterval, transferTime: TimeInterval) {
        var stats = hostStats[host] ?? CDNHostStats()
        stats.successCount += 1
        stats.consecutiveFailures = 0
        stats.isolatedUntil = nil
        stats.totalBytes += bytes
        // 有效吞吐按首字节之后的传输耗时近似（total - ttfb，至少 1ms）
        stats.totalTransferTime += max(0.001, transferTime - ttfb)
        stats.lastTTFB = ttfb
        hostStats[host] = stats
    }

    func recordFailure(host: String, category: CDNErrorCategory) {
        if case .cancelled = category { return }
        var stats = hostStats[host] ?? CDNHostStats()
        stats.failureCount += 1
        stats.consecutiveFailures += 1
        failureCount += 1
        // 连续失败 3 次则隔离 30s，避免无限重复同一无效候选
        if stats.consecutiveFailures >= 3 {
            stats.isolatedUntil = Date().addingTimeInterval(30)
        }
        hostStats[host] = stats
    }

    func isolateSingle(host: String) {
        var stats = hostStats[host] ?? CDNHostStats()
        stats.isolatedUntil = Date().addingTimeInterval(30)
        stats.consecutiveFailures += 1
        hostStats[host] = stats
    }

    func classify(error: Error?, status: Int?) -> CDNErrorCategory {
        if let status {
            switch status {
            case 403: return .forbidden
            case 404: return .notFound
            case 416: return .rangeNotSatisfiable
            case 429: return .tooManyRequests
            case 500...599: return .serverError(status: status)
            default: return .serverError(status: status)
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timeout
            case .cancelled: return .cancelled
            default: return .network(urlError)
            }
        }
        if error is CancellationError { return .cancelled }
        return .network(error ?? NSError(domain: "cdn", code: -1))
    }
}
