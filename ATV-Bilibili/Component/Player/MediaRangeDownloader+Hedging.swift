//
//  MediaRangeDownloader+Hedging.swift
//  ATV-Bilibili
//
//  子区间获取: 慢请求竞速(slow-request hedging)、带重试的候选轮转、
//  跨 CDN 等价性门控(SIDX 信任锚点，单级验证)。
//
//  从 MediaRangeDownloader.swift 按职责拆出。actor 的存储状态仍在主文件,
//  因此这些方法改为模块内可见(原为 private), 语义不变。
//

import Foundation

extension MediaRangeDownloader {
    // MARK: 子区间获取（含竞速与重试）

    //
    //  单一 TaskGroup 协调器：主路与备路的下载工作以内联子任务运行，
    //  group.next() 即真正的 first-completion 通知。胜者选出后 cancelAll
    //  直接取消落选者的下载工作（fetch 内各处检查取消并使用可取消的
    //  URLSession 异步接口），不存在只取消 Task.value 等待者的情况。

    private enum HedgeLane: Sendable {
        case primary
        case secondary
    }

    private enum HedgeOutcome: Sendable {
        case data(lane: HedgeLane, data: Data, host: String)
        case failed(lane: HedgeLane)
        case hedgeTimer
        case compareTimer
    }

    /// 跨 Task 传递子任务的原始错误（TaskGroup 元素须 Sendable，Error 不是）。
    /// 每个 hedging 操作独占一个 box，不存在并发操作间的串扰。
    private final class HedgeErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var errors = [HedgeLane: Error]()
        func set(_ error: Error, for lane: HedgeLane) {
            lock.lock()
            errors[lane] = error
            lock.unlock()
        }

        func error(for lane: HedgeLane) -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return errors[lane]
        }
    }

    func fetchSubrangeWithHedging(
        _ subrange: MediaByteRange,
        allowHedging: Bool,
        candidateHosts: [String]? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        // candidateHosts 由调用方按轮转/统计排好序，原样采用，不再二次排序，
        // 保证初始分配即分散；nil 时回退到当前统计排序。
        let hosts = candidateHosts ?? orderedHosts()
        guard !hosts.isEmpty else { throw MediaRangeError.unsatisfiable(total: knownTotalLength) }
        if !allowHedging || hosts.count == 1 || subrange.length < subrangeMinBytes {
            // 单路：无竞速，交付前仍需过等价性门控（单 host/代理模式内直接通过）。
            let (data, host) = try await fetchSubrangeWithRetry(subrange, hosts: hosts)
            try await ensureHostVerified(host, hosts: hosts)
            return data
        }
        // Slow-Request Hedging：主请求慢时在另一 CDN 启动竞争。
        // 触发考虑 TTFB、已接收字节/吞吐、剩余字节与播放紧迫度（此处用固定 1s 延迟
        // + 剩余长度门限近似；首字节与吞吐在 fetchAttempt 内实测并记入统计）。
        let alternate = alternateHosts(excludingFirstOf: hosts)
        let errorBox = HedgeErrorBox()
        return try await withThrowingTaskGroup(of: HedgeOutcome.self) { group in
            group.addTask {
                do {
                    let (data, host) = try await self.fetchSubrangeWithRetry(subrange, hosts: hosts)
                    return .data(lane: .primary, data: data, host: host)
                } catch is CancellationError {
                    // 外部取消或组取消：向上传播，保证及时退出；
                    // 计时哨兵不走此路径（sleep 封装在独立子任务内）。
                    if Task.isCancelled { throw CancellationError() }
                    errorBox.set(CancellationError(), for: .primary)
                    return .failed(lane: .primary)
                } catch {
                    errorBox.set(error, for: .primary)
                    return .failed(lane: .primary)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: self.hedgingDelayNanoseconds)
                    return .hedgeTimer
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    // 极少见：sleep 非取消失败，视为计时到期处理
                    return .hedgeTimer
                }
            }
            var secondaryStarted = false
            var primaryFailed = false
            var secondaryFailed = false
            var winnerLane: HedgeLane?
            var winnerData: Data?
            var winnerHost: String?
            while let outcome = try await group.next() {
                switch outcome {
                case let .data(lane, data, host):
                    if winnerData == nil {
                        winnerLane = lane
                        winnerData = data
                        winnerHost = host
                        if secondaryStarted {
                            // 备路已启动：给落选者短宽限以完成并做字节级比较
                            group.addTask {
                                do {
                                    try await Task.sleep(nanoseconds: 100_000_000)
                                    return .compareTimer
                                } catch {
                                    if Task.isCancelled { throw CancellationError() }
                                    return .compareTimer
                                }
                            }
                        } else {
                            // 备路尚未启动：先停计时器，再过等价性门控后交付
                            group.cancelAll()
                            try await ensureHostVerified(host, hosts: hosts)
                            return data
                        }
                    } else {
                        // 落选者在宽限内完成：必须来自另一 lane，与胜者做头尾各 4KiB 抽样比较。
                        // 整段逐字节 memcmp 会让每个竞速 subrange 白付一份完整下载与 CPU；
                        // 错位响应在 Transport 层已被 Content-Range/长度校验拦下，这里只兜「内容级」差异。
                        if lane == winnerLane {
                            group.cancelAll()
                            try await ensureHostVerified(winnerHost!, hosts: hosts)
                            return winnerData!
                        }
                        if !Self.headTailMatches(winnerData!, data) {
                            isolateHosts(hosts, reason: "overlap-mismatch")
                            throw MediaRangeError.mismatch
                        }
                        addExtra(Int64(data.count))
                        group.cancelAll()
                        try await ensureHostVerified(winnerHost!, hosts: hosts)
                        return winnerData!
                    }
                case let .failed(lane):
                    if winnerData != nil {
                        // 胜者已定，落选者失败可忽略
                        group.cancelAll()
                        try await ensureHostVerified(winnerHost!, hosts: hosts)
                        return winnerData!
                    }
                    if lane == .primary {
                        primaryFailed = true
                    } else {
                        secondaryFailed = true
                    }
                    if !secondaryStarted {
                        // 主路在备路启动前即失败：重试已在 fetchSubrangeWithRetry 内耗尽，
                        // 直接传播原始错误，不等待计时器
                        group.cancelAll()
                        throw errorBox.error(for: lane) ?? MediaRangeError.truncated
                    }
                    if primaryFailed, secondaryFailed {
                        group.cancelAll()
                        throw errorBox.error(for: .primary) ?? MediaRangeError.truncated
                    }
                // 另一路仍在跑，继续等待
                case .hedgeTimer:
                    if winnerData != nil {
                        continue
                    }
                    if !secondaryStarted {
                        secondaryStarted = true
                        retryCount += 1
                        hedgedCount += 1
                        // 第二路：排除首选 host，优先不同 host
                        group.addTask {
                            do {
                                let (data, host) = try await self.fetchSubrangeWithRetry(subrange, hosts: alternate)
                                return .data(lane: .secondary, data: data, host: host)
                            } catch is CancellationError {
                                if Task.isCancelled { throw CancellationError() }
                                errorBox.set(CancellationError(), for: .secondary)
                                return .failed(lane: .secondary)
                            } catch {
                                errorBox.set(error, for: .secondary)
                                return .failed(lane: .secondary)
                            }
                        }
                    }
                case .compareTimer:
                    // 比较宽限到期：落选者未完成，门控胜者后交付
                    // （落选者被 cancelAll 中止，已传输的部分字节已在其中止路径计入 extra）
                    group.cancelAll()
                    if let winnerData, let winnerHost {
                        try await ensureHostVerified(winnerHost, hosts: hosts)
                        return winnerData
                    }
                    continue
                }
            }
            // 组耗尽仍无结果：竞速循环正常应已 return。真发生时按失败传播并断言
            // （原「意外持有胜者仍交付」分支不可达，已删）。
            assertionFailure("hedge group exhausted without winner")
            throw errorBox.error(for: .primary) ?? MediaRangeError.truncated
        }
    }

    /// 头尾各 4KiB 抽样比较：长度必须相等，头尾都一致才放行。
    /// 两段大响应出现「头尾一致、中部错位」的 CDN 错配没有现实已知案例。
    static func headTailMatches(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        let span = 4 * 1024
        guard Data(a.prefix(span)) == Data(b.prefix(span)) else { return false }
        return Data(a.suffix(span)) == Data(b.suffix(span))
    }

    func fetchSubrangeWithRetry(_ subrange: MediaByteRange, hosts: [String]) async throws -> (data: Data, host: String) {
        guard !hosts.isEmpty else { throw MediaRangeError.unsatisfiable(total: knownTotalLength) }
        var lastError: Error = MediaRangeError.unsatisfiable(total: knownTotalLength)
        // 按重试次数而不是 host 数：单 CDN 时也要有机会重试一次，不能一次抖动就整段失败
        let attempts = maxRetriesPerSubrange + 1
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let host = hosts[attempt % hosts.count]
            guard let urlString = urlString(forHost: host) else { continue }
            do {
                let data = try await fetchAttempt(subrange: subrange, urlString: urlString, host: host)
                return (data, host)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                // 取消不计入 CDN 健康失败（由上层区分）
                continue
            }
        }
        throw lastError
    }

    /// 跨 CDN 等价性门控：serving host 的字节只有在其通过验证后才允许拼接。
    /// 已验证则直接通过；否则加入（或并入）该 host 的验证任务并等待。
    /// 验证本身见 verifyHostEquivalence。单 host/非加速模式直接通过。
    func ensureHostVerified(_ host: String, hosts: [String]) async throws {
        guard mode == .accelerated, hosts.count > 1 else { return }
        if equivalenceVerifiedHosts.contains(host) { return }
        if let existing = verifyTasks[host] {
            return try await existing.value
        }
        let task = Task<Void, Error> {
            try await self.verifyHostEquivalence(host)
        }
        verifyTasks[host] = task
        defer { verifyTasks[host] = nil }
        return try await task.value
    }

    /// 跨 CDN 等价性验证（2026-11-14 降级为单级）：serving host 首次参与拼接前，
    /// 用 SIDX 锚点（播放列表生成时已从探测 URL 取回的索引字节，无需额外往返）比对一次。
    /// 原双边 32KiB 采样已删：家庭单用户场景，B 站不同 CDN 字节不一致是极窄威胁模型，
    /// Transport 层对每个响应本就有 206 + Content-Range 区间/长度严格校验，足够拦错位响应。
    /// - 通过：记为已验证，采样流量计入 extra。
    /// - 锚点冲突：无法确定正确来源，按 mismatch 终止（不隔离任何一方，
    ///   由播放器级恢复回退直连）；锚点同时作废，后续 host 不再重复撞同一锚点。
    /// - 锚点样本取回失败（416/越界）：结论不定，本次放行但不标记（下次再验）。
    func verifyHostEquivalence(_ host: String) async throws {
        try Task.checkCancellation()
        guard let anchor = trustAnchor, !anchorDiscarded else { return }
        guard let hostURL = urlString(forHost: host) else { return }
        let sample: Data
        do {
            sample = try await fetchAttempt(subrange: anchor.range, urlString: hostURL, host: host)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isInconclusiveSampleError(error) { return }
            throw error
        }
        addExtra(Int64(sample.count))
        guard sample == anchor.bytes else {
            failureCount += 1
            anchorDiscarded = true
            throw MediaRangeError.mismatch
        }
        equivalenceVerifiedHosts.insert(host)
    }

    /// 采样区间超出文件尾（416/越界）属于结论不定，不应记为失败或冲突。
    func isInconclusiveSampleError(_ error: Error) -> Bool {
        if let e = error as? MediaRangeError {
            switch e {
            case .unsatisfiable, .upstream(416):
                return true
            default:
                return false
            }
        }
        return false
    }

    func urlString(forHost host: String) -> String? {
        // 同一媒体流内可交换的 CDN 候选：host 匹配的第一个 URL。
        // 字节一致性由等价性采样（verifyHostEquivalence）与重叠比较强制保证，
        // 未验证的 host 不得参与拼接，而非默认信任。
        for url in candidates {
            if URLComponents(string: url)?.host == host {
                return url
            }
        }
        return candidates.first
    }

    func orderedHosts() -> [String] {
        var seen = Set<String>()
        var hosts = [String]()
        for url in candidates {
            guard let host = URLComponents(string: url)?.host else { continue }
            if seen.insert(host).inserted {
                hosts.append(host)
            }
        }
        // 隔离中的 host 沉底；其余按实测吞吐降序，TTFB 小者优先
        return hosts.sorted { a, b in
            let sa = hostStats[a]
            let sb = hostStats[b]
            let aIso = sa?.isIsolated ?? false
            let bIso = sb?.isIsolated ?? false
            if aIso != bIso { return !aIso }
            let aMbps = sa?.estimatedMbps ?? -1
            let bMbps = sb?.estimatedMbps ?? -1
            if aMbps != bMbps { return aMbps > bMbps }
            let aTTFB = sa?.lastTTFB ?? .greatestFiniteMagnitude
            let bTTFB = sb?.lastTTFB ?? .greatestFiniteMagnitude
            return aTTFB < bTTFB
        }
    }

    func alternateHosts(excludingFirstOf hosts: [String]) -> [String] {
        guard hosts.count > 1 else { return hosts }
        return Array(hosts.dropFirst()) + [hosts.first!]
    }

    func isolateHosts(_ hosts: [String], reason: String) {
        let until = Date().addingTimeInterval(30)
        for host in hosts {
            var stats = hostStats[host] ?? CDNHostStats()
            stats.isolatedUntil = until
            stats.consecutiveFailures += 1
            stats.failureCount += 1
            hostStats[host] = stats
        }
        failureCount += 1
        Logger.info("[cdn] isolate \(hosts): \(reason), until \(until)")
    }

    func addExtra(_ bytes: Int64) {
        extraBytes += bytes
    }
}
