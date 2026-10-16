//
//  PagedProvider.swift
//  ATV-Bilibili
//
//  Created by ATV-Bilibili contributors on 2026/10/11.
//

import Foundation

/// page 游标分页加载的纯数据层状态机，不绑 UI。
/// 收编「我的-关注列表」与「关注页头像条」两处同源实现 (requestFollowing)。
/// 统一规则: 成功才推进页码; 拉取失败不停摆(下次滚动到底自动重试); refresh() 取消在途任务并整体替换。
@MainActor
final class PagedProvider<T> {
    private let fetch: (Int) async throws -> [T]
    /// 单页返回条数小于该值即视为到底 (requestFollowing 每页上限 40)
    private let finishThreshold: Int
    /// 可选去重键: 追加时过滤已有条目 (关注列表按 mid 去重)
    private let dedupKey: ((T) -> AnyHashable)?
    /// 滚动到倒数第几项时预取下一页 (1 = 最后一项)
    private let prefetchMargin: Int

    private(set) var items: [T] = []
    private(set) var finished = false
    private var page = 1
    private var requesting = false
    private var task: Task<Void, Never>?

    /// items 变化(刷新/追加成功)后回调; 刷新失败不回调, 使用方保留旧数据
    var onItemsChange: (() -> Void)?

    init(fetch: @escaping (Int) async throws -> [T],
         finishThreshold: Int = 40,
         dedupKey: ((T) -> some Hashable)? = nil,
         prefetchMargin: Int = 1)
    {
        self.fetch = fetch
        self.finishThreshold = finishThreshold
        self.dedupKey = dedupKey.map { key in { AnyHashable(key($0)) } }
        self.prefetchMargin = prefetchMargin
    }

    deinit {
        task?.cancel()
    }

    /// 拉取第一页并整体替换; 取消在途任务, 失败保留旧数据。账号切换/下拉刷新都走这里。
    func refresh() {
        task?.cancel()
        task = Task { await performRefresh() }
    }

    /// 滚动到 index 时是否应触发下一页拉取 (余量判定)
    func shouldLoadMore(atIndex index: Int) -> Bool {
        !requesting && !finished && !items.isEmpty && index >= items.count - prefetchMargin
    }

    /// 滚动到余量内时调用, 内部判断是否需要拉取下一页
    func loadMoreIfNeeded(atIndex index: Int) {
        guard shouldLoadMore(atIndex: index) else { return }
        task = Task { await performLoadMore() }
    }

    /// 以下两个供测试直接 await; UI 侧走 refresh()/loadMoreIfNeeded()
    func performRefresh() async {
        requesting = true
        do {
            let first = try await fetch(1)
            guard !Task.isCancelled else { return }
            items = first
            page = 1
            finished = first.count < finishThreshold
            onItemsChange?()
        } catch {
            // 刷新失败保留旧列表; 首次加载失败维持空态
        }
        requesting = false
    }

    func performLoadMore() async {
        guard !requesting, !finished, !items.isEmpty else { return }
        requesting = true
        let pageToFetch = page + 1
        do {
            let next = try await fetch(pageToFetch)
            guard !Task.isCancelled else { return }
            appendDeduped(next)
            if !next.isEmpty { page = pageToFetch }
            finished = next.count < finishThreshold
            onItemsChange?()
        } catch {
            // 拉取失败不停摆: 页码未推进, 下次滚动到底自动重试
        }
        requesting = false
    }

    private func appendDeduped(_ next: [T]) {
        guard let dedupKey else {
            items.append(contentsOf: next)
            return
        }
        var known = Set(items.map(dedupKey))
        items.append(contentsOf: next.filter { known.insert(dedupKey($0)).inserted })
    }
}
