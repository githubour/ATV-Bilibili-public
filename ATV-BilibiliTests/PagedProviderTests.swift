//
//  PagedProviderTests.swift
//  ATV-BilibiliTests
//

@testable import ATV_Bilibili
import XCTest

@MainActor
final class PagedProviderTests: XCTestCase {
    /// 可编程假数据源: 记录每次拉取的页码, 按 页码->结果/错误 脚本应答
    private final class StubSource {
        var fetchedPages = [Int]()
        var script = [Int: Result<[Int], Error>]()

        @MainActor
        func makeProvider(finishThreshold: Int = 40,
                          dedupKey: ((Int) -> Int)? = nil,
                          prefetchMargin: Int = 1) -> PagedProvider<Int>
        {
            PagedProvider(fetch: { [self] page in
                fetchedPages.append(page)
                guard let result = script[page] else { return [] }
                return try result.get()
            }, finishThreshold: finishThreshold, dedupKey: dedupKey, prefetchMargin: prefetchMargin)
        }
    }

    private struct StubError: Error {}

    func test_refresh_replacesItemsAndSignalsChange() async {
        let source = StubSource()
        source.script[1] = .success([1, 2, 3])
        let provider = source.makeProvider()
        var changeCount = 0
        provider.onItemsChange = { changeCount += 1 }

        await provider.performRefresh()
        XCTAssertEqual(provider.items, [1, 2, 3])
        XCTAssertTrue(provider.finished, "首屏 3 条 < 40 应视为到底")
        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(source.fetchedPages, [1])
    }

    func test_refresh_fullPageNotFinished() async {
        let source = StubSource()
        source.script[1] = .success(Array(0..<40))
        let provider = source.makeProvider()

        await provider.performRefresh()
        XCTAssertFalse(provider.finished, "满页 40 条说明可能还有下一页")
    }

    func test_refresh_failureKeepsOldItems() async {
        let source = StubSource()
        source.script[1] = .success(Array(0..<40))
        let provider = source.makeProvider()
        await provider.performRefresh()

        source.script[1] = .failure(StubError())
        var changeCount = 0
        provider.onItemsChange = { changeCount += 1 }
        await provider.performRefresh()
        XCTAssertEqual(provider.items, Array(0..<40), "刷新失败应保留旧列表")
        XCTAssertEqual(changeCount, 0, "刷新失败不应触发 onItemsChange")
        XCTAssertFalse(provider.finished)
    }

    func test_loadMore_appendsAndAdvancesPage() async {
        let source = StubSource()
        source.script[1] = .success(Array(0..<40))
        source.script[2] = .success(Array(40..<80))
        let provider = source.makeProvider()
        await provider.performRefresh()

        await provider.performLoadMore()
        XCTAssertEqual(provider.items.count, 80)
        XCTAssertFalse(provider.finished, "第二页仍满 40 条")
        XCTAssertEqual(source.fetchedPages, [1, 2])
    }

    func test_loadMore_failureDoesNotStall_andRetriesSamePage() async {
        let source = StubSource()
        source.script[1] = .success(Array(0..<40))
        source.script[2] = .failure(StubError())
        let provider = source.makeProvider()
        await provider.performRefresh()

        await provider.performLoadMore()
        XCTAssertEqual(provider.items.count, 40, "拉取失败不应改动现有数据")
        XCTAssertFalse(provider.finished, "失败不应置 finished 停摆")

        source.script[2] = .success([40])
        await provider.performLoadMore()
        XCTAssertEqual(provider.items.count, 41, "重试应仍拉第 2 页(页码未被污染)")
        XCTAssertEqual(source.fetchedPages, [1, 2, 2])
    }

    func test_loadMore_dedupesByKey() async {
        let source = StubSource()
        source.script[1] = .success(Array(0..<40))
        source.script[2] = .success([39, 40, 40, 41])
        let provider = source.makeProvider(dedupKey: { $0 })
        await provider.performRefresh()

        await provider.performLoadMore()
        XCTAssertEqual(provider.items, Array(0..<42), "跨页重复条目应被过滤")
    }

    func test_loadMore_emptyPageMarksFinished() async {
        let source = StubSource()
        source.script[1] = .success(Array(0..<40))
        source.script[2] = .success([])
        let provider = source.makeProvider()
        await provider.performRefresh()

        await provider.performLoadMore()
        XCTAssertTrue(provider.finished, "空页即到底")
        XCTAssertFalse(provider.shouldLoadMore(atIndex: 39), "finished 后不应再触发")
        await provider.performLoadMore()
        XCTAssertEqual(source.fetchedPages, [1, 2], "finished 后不应再发请求")
    }

    func test_loadMore_belowPrefetchMarginDoesNotFetch() async {
        let source = StubSource()
        source.script[1] = .success(Array(0..<40))
        source.script[2] = .success([99])
        let provider = source.makeProvider()
        await provider.performRefresh()

        XCTAssertFalse(provider.shouldLoadMore(atIndex: 38), "距底部还有余量时不应预取")
        XCTAssertTrue(provider.shouldLoadMore(atIndex: 39), "最后一项才触发")
        await provider.performLoadMore()
        XCTAssertEqual(provider.items, Array(0..<40) + [99])
        XCTAssertEqual(source.fetchedPages, [1, 2])
    }
}
