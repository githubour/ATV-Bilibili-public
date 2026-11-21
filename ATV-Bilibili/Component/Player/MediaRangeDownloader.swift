//
//  MediaRangeDownloader.swift
//  ATV-Bilibili
//
//  会话级自适应多 CDN 并发 Range 下载器（PR2）。
//  职责：有界并发、子块切分、CDN 健康模型、慢请求竞速、严格校验、有序流式交付。
//  状态限定在当前媒体流/播放会话内，不跨视频持久化，不持有全局 CDN 排名。
//
//  本文件只保留 actor 的状态与调度主干（对外接口 / 切分 / 单路 / 并发流式）。
//  按职责拆出的同目录文件:
//    · MediaDownloadBudget.swift          全局并发预算（actor + 许可 token）
//    · MediaRangeModels.swift             传输上限 / CDN 错误分类 / host 统计 / 诊断快照
//    · MediaBytePipe.swift                有界字节通道
//    · MediaRangeDownloader+Hedging.swift 子区间竞速、重试、跨 CDN 等价性门控
//    · MediaRangeDownloader+Transport.swift 单次请求(严格校验)、预算等待、统计记账
//

import Foundation

// MARK: - 下载器

/// 单个播放会话拥有的 actor。
/// 播放器不需要知道一个 Range 被拆成几个下载任务。
actor MediaRangeDownloader {
    // 内部自适应参数（初始建议值，非最优声明，实测调整）。
    let subrangeTargetBytes: Int64 = 512 * 1024 // 256KiB–1MiB 区间内
    let subrangeMaxBytes: Int64 = 1 * 1024 * 1024
    let subrangeMinBytes: Int64 = 256 * 1024
    let maxConcurrentPerMedia = 4
    let maxBufferedBytes: Int64 = 4 * 1024 * 1024
    let maxRetriesPerSubrange = 2
    let hedgingDelayNanoseconds: UInt64 = 1_000_000_000 // 1s
    let singleRequestMemoryCap: Int64 = MediaDownloadLimits.singleRequestMemoryCap

    let candidates: [String]
    let referer: String
    let userAgent: String
    let mode: MediaTransportMode

    var hostStats = [String: CDNHostStats]()
    var knownTotalLength: Int64?
    var deliveredBytes: Int64 = 0
    var extraBytes: Int64 = 0
    var failureCount = 0
    var retryCount = 0
    var hedgedCount = 0
    var activeSubrequests = 0
    /// 当前实际在途的子请求按 host 计数（诊断用，与累计统计 hostStats.keys 区分）。
    var activeHostCounts = [String: Int]()
    var downgradedToDirect = false
    /// AIMD 自适应并发上限：成功且无竞速/失败时 +1，失败时减半；
    /// 范围 [1, maxConcurrentPerMedia]，初始 2。仅调节并发数，不共享 CDN 排名。
    var adaptiveConcurrency = 2
    /// 已通过跨 CDN 等价性采样的 host（本媒体流内有效）。未采样 host 的字节
    /// 不得参与拼接，防止不同版本内容混入同一 Range 解码。
    var equivalenceVerifiedHosts = Set<String>()
    /// 同一 host 的并发验证任务合并：后来者直接并入等待，不重复采样。
    var verifyTasks = [String: Task<Void, Error>]()
    /// SIDX 锚点：播放列表生成时从 sidx 探测 URL 取回的 (索引区间, 原始字节)，
    /// 作为等价性验证的可信参照（免额外采样往返）。缺失或作废时验证直接放行不标记
    /// （见 verifyHostEquivalence；原「双边采样」退化路径已删，2026-11-14 降级为单级）。
    var trustAnchor: (range: MediaByteRange, bytes: Data)?
    /// 锚点作废标记：一旦确认冲突即永久丢弃；此后各 host 不再验证、直接放行。
    var anchorDiscarded = false

    var session: URLSession?

    init(candidates: [String], referer: String, userAgent: String = Keys.userAgent, mode: MediaTransportMode = .accelerated) {
        self.candidates = candidates
        self.referer = referer
        self.userAgent = userAgent
        self.mode = mode
    }

    deinit {
        session?.invalidateAndCancel()
    }

    // MARK: 对外接口

    /// 流式下载：边下载边按顺序向 pipe 交付已验证字节，完成后 close，失败时 fail。
    /// 同一个请求最多交付一次，每次交付严格递增。
    func stream(range: MediaByteRange, to pipe: MediaBytePipe) async {
        do {
            try Task.checkCancellation()
            guard !candidates.isEmpty else {
                pipe.fail(MediaRangeError.unsatisfiable(total: nil))
                return
            }
            guard range.length <= singleRequestMemoryCap else {
                // 超出安全容量：不做无界缓存，由调用方降级直连
                downgradedToDirect = true
                pipe.fail(MediaRangeError.unsatisfiable(total: knownTotalLength))
                return
            }
            let subranges = split(range: range)
            if mode == .proxy || subranges.count == 1 {
                await streamSingle(range: range, to: pipe)
                return
            }
            await streamConcurrent(parentRange: range, subranges: subranges, to: pipe)
        } catch is CancellationError {
            pipe.fail(MediaRangeError.cancelled)
        } catch {
            pipe.fail(error)
        }
    }

    func diagnostics() -> MediaRangeDiagnostics {
        // activeHosts 必须是当前实际在途的 host 数，而非累计出现过的 host 数。
        let activeHosts = activeHostCounts.count
        // 有效总吞吐按各 host 实测吞吐求和：多 host 并行时体现聚合，
        // 单 host 串行时退化为该 host 的实测值。累计字节/累计时间之比会低估并行吞吐。
        let mbps = hostStats.values.compactMap(\.estimatedMbps).reduce(0, +)
        return MediaRangeDiagnostics(
            transportMode: mode,
            activeHosts: activeHosts,
            estimatedAggregateMbps: mbps,
            activeSubrequests: activeSubrequests,
            failures: failureCount,
            retries: retryCount,
            deliveredBytes: deliveredBytes,
            extraBytes: extraBytes,
            downgradedToDirect: downgradedToDirect
        )
    }

    func knownTotal() -> Int64? {
        knownTotalLength
    }

    /// 设置 SIDX 信任锚点（播放列表生成时调用，幂等覆盖同一值）。
    /// 锚点仅用于等价性验证的参照，不参与媒体数据交付。
    func setTrustAnchor(range: MediaByteRange, bytes: Data) {
        if trustAnchor == nil {
            trustAnchor = (range, bytes)
        }
    }

    // MARK: 切分

    func split(range: MediaByteRange) -> [MediaByteRange] {
        if range.length <= subrangeMinBytes {
            return [range]
        }
        var result = [MediaByteRange]()
        var cursor = range.start
        // 目标 512KiB，大请求分块，小请求不强拆
        let chunk: Int64 = min(max(subrangeTargetBytes, range.length / Int64(maxConcurrentPerMedia)), subrangeMaxBytes)
        while cursor <= range.end {
            let end = min(cursor + chunk - 1, range.end)
            // 避免产生过小的尾块：剩余不足 min 则并入当前块
            let remaining = range.end - end
            if remaining > 0, remaining < subrangeMinBytes {
                if let merged = try? MediaByteRange(start: cursor, end: range.end) {
                    result.append(merged)
                }
                break
            }
            if let piece = try? MediaByteRange(start: cursor, end: end) {
                result.append(piece)
            }
            cursor = end + 1
        }
        return result.isEmpty ? [range] : result
    }

    // MARK: 单路（proxy 测试模式）

    private func streamSingle(range: MediaByteRange, to pipe: MediaBytePipe) async {
        do {
            let data = try await fetchSubrangeWithHedging(range, allowHedging: false)
            try await pipe.write(data)
            deliveredBytes += Int64(data.count)
            pipe.close()
        } catch is CancellationError {
            pipe.fail(MediaRangeError.cancelled)
        } catch {
            pipe.fail(error)
        }
    }

    // MARK: 并发流式

    //
    //  单一 TaskGroup 协调器：子区间下载工作以内联子任务形式运行，
    //  group.next() 即真正的 first-completion 通知。选出首个完成即交付或继续，
    //  落选者在 cancelAll 后因工作内联、可取消而迅速退出——不存在只取消
    //  Task.value 等待者、底层下载继续跑的情况。

    private func streamConcurrent(parentRange: MediaByteRange, subranges: [MediaByteRange], to pipe: MediaBytePipe) async {
        // 有序交付状态（仅本请求内有效）
        var pending = [Int: Data]()
        var pendingBytes: Int64 = 0
        var nextToDeliver = 0
        var nextToStart = 0
        // 本次 stream 的 outcome 快照（AIMD 用）：开始前记录，结束后比较
        let failuresBefore = failureCount
        let hedgesBefore = hedgedCount

        // 子区间初始分配按 host 轮转：无统计时各子区间即分散到不同 CDN，
        // 而非全部挤在首选 host 上等 Hedging 救援。统计出现后 orderedHosts 本身已排序。
        // AIMD 当前上限快照（本请求内固定，避免中途抖动）
        let concurrencyLimit = max(1, min(maxConcurrentPerMedia, adaptiveConcurrency))
        // 本请求的独立在途计数：同一下载器可同时服务多个 Range 请求，
        // 调度槽位必须按请求隔离；共享的 activeSubrequests 仅作诊断，
        // 跨请求的真实网络并发上限由 MediaDownloadBudget 负责。
        var inFlight = 0
        // 异常退出（失败/取消）时把本请求未扣减的诊断计数一次性归还；
        // 成功路径 inFlight 已归零，此处为无操作。
        defer { activeSubrequests = max(0, activeSubrequests - inFlight) }
        do {
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                while nextToDeliver < subranges.count {
                    if Task.isCancelled {
                        group.cancelAll()
                        throw CancellationError()
                    }
                    // 优先交付已就绪的最早分块（播放截止时间优先）
                    if let ready = pending[nextToDeliver] {
                        do {
                            try await pipe.write(ready)
                        } catch {
                            group.cancelAll()
                            throw error
                        }
                        deliveredBytes += Int64(ready.count)
                        pendingBytes -= Int64(ready.count)
                        pending[nextToDeliver] = nil
                        nextToDeliver += 1
                        continue
                    }
                    // 按本请求的独立计数补充在途任务（背压：已完成未交付超限则暂停）
                    while nextToStart < subranges.count,
                          inFlight < concurrencyLimit,
                          pendingBytes < maxBufferedBytes
                    {
                        let index = nextToStart
                        let sub = subranges[index]
                        let hosts = hostsForSubrange(index)
                        nextToStart += 1
                        inFlight += 1
                        activeSubrequests += 1
                        group.addTask {
                            let data = try await self.fetchSubrangeWithHedging(sub, allowHedging: true, candidateHosts: hosts)
                            return (index, data)
                        }
                    }
                    // first-completion：工作内联，取消即作用于下载本身。
                    // next() 返回即同步扣减本请求计数，不经延迟的 Task 跳转，
                    // 调度器看到的槽位永远是最新的。
                    guard let (index, data) = try await group.next() else {
                        throw MediaRangeError.truncated
                    }
                    inFlight -= 1
                    activeSubrequests = max(0, activeSubrequests - 1)
                    // 长度校验：必须是请求子区间的准确长度
                    guard Int64(data.count) == subranges[index].length else {
                        group.cancelAll()
                        failureCount += 1
                        throw MediaRangeError.truncated
                    }
                    pending[index] = data
                    pendingBytes += Int64(data.count)
                }
            }
            // 完整覆盖校验
            guard nextToDeliver == subranges.count else {
                pipe.fail(MediaRangeError.truncated)
                adjustConcurrencyAfterStream(failuresBefore: failuresBefore, hedgesBefore: hedgesBefore, succeeded: false)
                return
            }
            adjustConcurrencyAfterStream(failuresBefore: failuresBefore, hedgesBefore: hedgesBefore, succeeded: true)
            pipe.close()
        } catch is CancellationError {
            adjustConcurrencyAfterStream(failuresBefore: failuresBefore, hedgesBefore: hedgesBefore, succeeded: false)
            pipe.fail(MediaRangeError.cancelled)
        } catch {
            // 失败计数已在成因处恰好记一次（recordFailure/isolateHosts/等价性验证），
            // 此处不再重复累加，保证诊断诚实；取消与预算耗尽本就不计入 CDN 失败。
            adjustConcurrencyAfterStream(failuresBefore: failuresBefore, hedgesBefore: hedgesBefore, succeeded: false)
            pipe.fail(error)
        }
    }

    /// 子区间首选 host 轮转：把第 index 个子区间优先分配给第 (index % hosts) 个 host，
    /// 使首轮并发即分散到不同 CDN，实现聚合；之后按实测统计排序。
    private func hostsForSubrange(_ index: Int) -> [String] {
        let base = orderedHosts()
        guard base.count > 1 else { return base }
        let r = index % base.count
        return Array(base[r...] + base[..<r])
    }

    /// AIMD：干净成功（无新增失败、无竞速）则 +1 试探；失败则减半。
    /// 缓冲背压（pendingBytes 上限暂停新任务）独立于该调节，始终生效。
    private func adjustConcurrencyAfterStream(failuresBefore: Int, hedgesBefore: Int, succeeded: Bool) {
        if succeeded, failureCount == failuresBefore, hedgedCount == hedgesBefore {
            adaptiveConcurrency = min(maxConcurrentPerMedia, adaptiveConcurrency + 1)
        } else if !succeeded {
            adaptiveConcurrency = max(1, adaptiveConcurrency / 2)
        }
        // 成功但发生过竞速/失败：保持当前上限不变
    }
}
