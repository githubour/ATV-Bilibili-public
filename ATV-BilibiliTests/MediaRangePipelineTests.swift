//
//  MediaRangePipelineTests.swift
//  ATV-BilibiliTests
//
//  MediaRangeDownloader 拆分前的纯逻辑回归基线：
//    · 子块切分（覆盖完整、不重叠、不产生过小尾块）
//    · CDN 健康模型的吞吐/隔离判定、诊断冗余比
//    · 有界字节通道的背压/关闭/失败/超时语义
//    · 媒体代理注册表的 id 复用与快照隔离（跨文件拆分时的“缓存键”契约）
//    · 兜底清单的 host 偏好选择
//  这些都不依赖 AVFoundation 播放链路，拆分 3 个巨型文件后必须原样通过。
//

@testable import ATV_Bilibili
import XCTest

final class MediaRangePipelineTests: XCTestCase {
    // MARK: - 子块切分

    private func makeDownloader() -> MediaRangeDownloader {
        MediaRangeDownloader(candidates: [
            "https://a.example.com/v.m4s?x=1",
            "https://b.example.com/v.m4s?x=1",
        ], referer: "https://www.bilibili.com/")
    }

    /// 切分结果必须无缝覆盖原区间：首块起点对齐、末块终点对齐、相邻块首尾相接。
    private func assertCoversExactly(_ pieces: [MediaByteRange], _ range: MediaByteRange,
                                     file: StaticString = #filePath, line: UInt = #line)
    {
        XCTAssertFalse(pieces.isEmpty, "切分结果不能为空", file: file, line: line)
        XCTAssertEqual(pieces.first?.start, range.start, "首块必须从区间起点开始", file: file, line: line)
        XCTAssertEqual(pieces.last?.end, range.end, "末块必须覆盖到区间终点", file: file, line: line)
        var expected = range.start
        for piece in pieces {
            XCTAssertEqual(piece.start, expected, "子块之间有空洞或重叠", file: file, line: line)
            XCTAssertGreaterThan(piece.length, 0, "不允许空子块", file: file, line: line)
            expected = piece.end + 1
        }
        XCTAssertEqual(expected, range.end + 1, "末块之后不应再有缺口", file: file, line: line)
    }

    func testSplitSmallRangeStaysSingle() async throws {
        let downloader = makeDownloader()
        let range = try MediaByteRange(start: 0, end: 200 * 1024 - 1)
        let pieces = await downloader.split(range: range)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].start, 0)
        XCTAssertEqual(pieces[0].end, 200 * 1024 - 1)
    }

    func testSplitExactMinimumStaysSingle() async throws {
        let downloader = makeDownloader()
        let range = try MediaByteRange(start: 4096, end: 4096 + 256 * 1024 - 1)
        let pieces = await downloader.split(range: range)
        XCTAssertEqual(pieces.count, 1, "恰好等于最小子块阈值时不强拆")
        assertCoversExactly(pieces, range)
    }

    func testSplitTwoMiBProducesFourHalfMiBPieces() async throws {
        let downloader = makeDownloader()
        let range = try MediaByteRange(start: 0, end: 2 * 1024 * 1024 - 1)
        let pieces = await downloader.split(range: range)
        XCTAssertEqual(pieces.count, 4)
        for piece in pieces {
            XCTAssertEqual(piece.length, 512 * 1024)
        }
        assertCoversExactly(pieces, range)
    }

    func testSplitLargeRangeCapsChunkAtOneMiB() async throws {
        let downloader = makeDownloader()
        let range = try MediaByteRange(start: 0, end: 8 * 1024 * 1024 - 1)
        let pieces = await downloader.split(range: range)
        XCTAssertEqual(pieces.count, 8)
        XCTAssertEqual(pieces.map(\.length).max(), 1024 * 1024)
        assertCoversExactly(pieces, range)
    }

    func testSplitMergesTooSmallTail() async throws {
        let downloader = makeDownloader()
        // 512KiB 整块 + 100KiB 尾巴：尾巴小于最小子块，必须并入前一块而不是单独发一个小请求
        let range = try MediaByteRange(start: 0, end: 612 * 1024 - 1)
        let pieces = await downloader.split(range: range)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].length, 612 * 1024)
        assertCoversExactly(pieces, range)
    }

    func testSplitNonZeroOriginKeepsCoverage() async throws {
        let downloader = makeDownloader()
        let range = try MediaByteRange(start: 12345, end: 12345 + 3 * 1024 * 1024 - 1)
        let pieces = await downloader.split(range: range)
        XCTAssertGreaterThan(pieces.count, 1)
        assertCoversExactly(pieces, range)
    }

    // MARK: - CDN 健康模型

    func testHostStatsEstimatedMbpsNeedsBothCounters() {
        var stats = CDNHostStats()
        XCTAssertNil(stats.estimatedMbps, "没有样本时不能给出吞吐")

        stats.totalBytes = 1_000_000
        XCTAssertNil(stats.estimatedMbps, "只有字节没有耗时不算吞吐")

        stats.totalTransferTime = 1
        XCTAssertEqual(stats.estimatedMbps ?? -1, 8, accuracy: 0.0001, "1MB/1s = 8Mbps")
    }

    func testHostStatsIsolationWindow() {
        var stats = CDNHostStats()
        XCTAssertFalse(stats.isIsolated)

        stats.isolatedUntil = Date().addingTimeInterval(30)
        XCTAssertTrue(stats.isIsolated)

        stats.isolatedUntil = Date().addingTimeInterval(-1)
        XCTAssertFalse(stats.isIsolated, "过期隔离必须自动失效")
    }

    func testDiagnosticsRedundancyRatioIsZeroSafe() {
        var diag = MediaRangeDiagnostics(transportMode: .accelerated, activeHosts: 1,
                                         estimatedAggregateMbps: 10, activeSubrequests: 2,
                                         failures: 0, retries: 0, deliveredBytes: 0,
                                         extraBytes: 128, downgradedToDirect: false)
        XCTAssertEqual(diag.redundancyRatio, 0, "未交付任何字节时不得除零")

        diag.deliveredBytes = 1000
        diag.extraBytes = 250
        XCTAssertEqual(diag.redundancyRatio, 0.25, accuracy: 0.0001)
    }

    // MARK: - 有界字节通道

    func testBytePipeDeliversInOrderThenEOF() async throws {
        let pipe = MediaBytePipe()
        try await pipe.write(Data([1, 2, 3]))
        try await pipe.write(Data([4, 5]))
        pipe.close()

        var collected = Data()
        while let chunk = try pipe.readSync(maxLength: 2, timeout: 5) {
            collected.append(chunk)
        }
        XCTAssertEqual(Array(collected), [1, 2, 3, 4, 5])
    }

    func testBytePipeCloseOnEmptyIsEOF() throws {
        let pipe = MediaBytePipe()
        pipe.close()
        XCTAssertNil(try pipe.readSync(maxLength: 16, timeout: 1))
    }

    func testBytePipeFailureSurfacesToReader() throws {
        let pipe = MediaBytePipe()
        pipe.fail(MediaRangeError.truncated)
        XCTAssertThrowsError(try pipe.readSync(maxLength: 16, timeout: 1)) { error in
            guard case MediaBytePipe.PipeError.failed = error else {
                return XCTFail("应透出 failed 包装，实际 \(error)")
            }
        }
    }

    func testBytePipeReadTimeout() throws {
        let pipe = MediaBytePipe()
        XCTAssertThrowsError(try pipe.readSync(maxLength: 16, timeout: 0.1)) { error in
            guard case MediaBytePipe.PipeError.readTimeout = error else {
                return XCTFail("空通道无新数据应抛 readTimeout，实际 \(error)")
            }
        }
    }

    /// 写满容量后写方必须挂起，读到腾出空间后才继续 —— 背压不能靠丢数据或无限缓存实现。
    /// 注意：单次 write 的数据块必须不超过容量（生产路径是 512KiB 子区间 / 2MiB 缓冲），
    /// 这里用 4 个 32KiB 块写跨过 64KiB 容量边界来触发背压。
    func testBytePipeBackpressureNeverDropsBytes() async throws {
        let capacity = 64 * 1024
        let pipe = MediaBytePipe(capacityBytes: capacity)
        let chunk = Data(repeating: 0x5A, count: 32 * 1024)
        let rounds = 4
        let writer = Task { () in
            for _ in 0..<rounds {
                try await pipe.write(chunk)
            }
            pipe.close()
        }

        var collected = Data()
        while let piece = try pipe.readSync(maxLength: 8 * 1024, timeout: 10) {
            collected.append(piece)
        }
        try await writer.value
        XCTAssertEqual(collected.count, chunk.count * rounds, "读出量必须等于写入总量")
        XCTAssertEqual(Array(collected), Array(Data(repeating: 0x5A, count: collected.count)),
                       "顺序与内容必须逐字节一致")
    }

    // MARK: - 媒体代理注册表（媒体 id 即代理层缓存键）

    private func makeMedia(base: String, id: Int = 80) -> VideoPlayURLInfo.DashInfo.DashMediaInfo {
        .init(id: id, base_url: base, backup_url: nil,
              bandwidth: 1_000_000, mime_type: "video/mp4", codecs: "avc1.640034",
              width: 1920, height: 1080, frame_rate: "30.000", sar: nil,
              start_with_sap: nil,
              segment_base: .init(initialization: "0-999", index_range: "1000-1999"),
              codecid: nil)
    }

    private func makeDownloaderForRegistry() -> MediaRangeDownloader {
        MediaRangeDownloader(candidates: ["https://cdn.example.com/v.m4s"], referer: "https://www.bilibili.com/")
    }

    func testRegistryReusesIDForSameMedia() {
        let registry = MediaProxyRegistry()
        let media = makeMedia(base: "https://cdn.example.com/v.m4s")
        registry.register(media: media,
                          candidates: ["https://cdn.example.com/v.m4s"],
                          referer: "https://www.bilibili.com/",
                          downloader: makeDownloaderForRegistry())
        let first = registry.id(for: media)
        XCTAssertNotNil(first)

        registry.register(media: media,
                          candidates: ["https://other.example.com/v.m4s"],
                          referer: "https://www.bilibili.com/",
                          downloader: makeDownloaderForRegistry())
        XCTAssertEqual(registry.id(for: media), first, "同一媒体重复注册必须复用 id，且不覆盖候选")
        XCTAssertEqual(registry.snapshot(for: first!)?.candidates, ["https://cdn.example.com/v.m4s"])
    }

    func testRegistrySeparatesDistinctMedia() {
        let registry = MediaProxyRegistry()
        let video = makeMedia(base: "https://cdn.example.com/v.m4s", id: 80)
        let audio = makeMedia(base: "https://cdn.example.com/a.m4s", id: 30280)
        registry.register(media: video, candidates: ["https://cdn.example.com/v.m4s"],
                          referer: "r", downloader: makeDownloaderForRegistry())
        registry.register(media: audio, candidates: ["https://cdn.example.com/a.m4s"],
                          referer: "r", downloader: makeDownloaderForRegistry())
        XCTAssertNotEqual(registry.id(for: video), registry.id(for: audio),
                          "不同清晰度/轨道不得共用代理 id")
    }

    func testRegistrySnapshotReflectsTotalLengthUpdate() {
        let registry = MediaProxyRegistry()
        let media = makeMedia(base: "https://cdn.example.com/v.m4s")
        registry.register(media: media, candidates: ["https://cdn.example.com/v.m4s"],
                          referer: "r", downloader: makeDownloaderForRegistry())
        guard let id = registry.id(for: media) else { return XCTFail("注册后应有 id") }
        XCTAssertNil(registry.snapshot(for: id)?.totalLength)

        registry.updateTotalLength(4096, for: id)
        XCTAssertEqual(registry.snapshot(for: id)?.totalLength, 4096)

        registry.removeAll()
        XCTAssertNil(registry.snapshot(for: id), "removeAll 后不得残留代理条目")
        XCTAssertNil(registry.id(for: media))
    }

    // MARK: - 兜底清单的 host 偏好

    private func makePlaybackInfo(urls: [String]) -> BilibiliVideoResourceLoaderDelegate.PlaybackInfo {
        .init(info: makeMedia(base: urls.first ?? ""), urls: urls, duration: 60)
    }

    func testFallbackURLPrefersCurrentHost() {
        let info = makePlaybackInfo(urls: [
            "https://a.example.com/v.m4s",
            "https://b.example.com/v.m4s",
        ])
        XCTAssertEqual(info.fallbackURL(preferringHost: "b.example.com"),
                       "https://b.example.com/v.m4s")
    }

    func testFallbackURLFallsBackToFirstCandidate() {
        let info = makePlaybackInfo(urls: [
            "https://a.example.com/v.m4s",
            "https://b.example.com/v.m4s",
        ])
        XCTAssertEqual(info.fallbackURL(preferringHost: nil), "https://a.example.com/v.m4s")
        XCTAssertEqual(info.fallbackURL(preferringHost: ""), "https://a.example.com/v.m4s")
        XCTAssertEqual(info.fallbackURL(preferringHost: "unknown.example.com"),
                       "https://a.example.com/v.m4s")
    }
}
