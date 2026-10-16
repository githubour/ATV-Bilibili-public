//
//  FollowsFeedFlowDataSource.swift
//  ATV-Bilibili
//
//  Created by ATV-Bilibili contributors on 2026/10/11.
//

import Foundation

/// 关注页刷视频模式 (设置里可切换)
final class FollowsFeedFlowViewController: FeedFlowBrowserViewController {
    init() {
        super.init(dataSource: FollowsFeedFlowDataSource())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 关注流数据源: offset+page 双游标, 单循环凑够 targetCount 后一次性 commit
final class FollowsFeedFlowDataSource: FeedFlowDataSource {
    let title = "关注"
    let defaultPreviewHintText = "停留后自动预览，按确认键进入视频流"
    let loadingHintText = "正在加载关注视频..."
    let emptyStateText = "当前关注区暂无可播放视频"
    let emptyHintText = "可以在设置中关闭关注刷视频模式"
    let loadFailureText = "关注加载失败，请稍后重试"
    let autoReloadInterval: TimeInterval? = 60 * 60

    var reloadToken: String {
        "\(ApiRequest.getToken()?.mid ?? 0)"
    }

    private var lastOffset = ""
    private var nextPage = 1
    private var hasMore = true
    private var seenItemKeys = Set<String>()

    private struct LoadResult {
        let items: [FeedFlowItem]
        let lastOffset: String
        let nextPage: Int
        let hasMore: Bool
        let seenItemKeys: Set<String>
    }

    func reset() {
        lastOffset = ""
        nextPage = 1
        hasMore = true
        seenItemKeys = []
    }

    func refreshFromStart(targetCount: Int, maxSourcePages: Int) async throws -> [FeedFlowItem] {
        let result = try await loadMoreUntilTarget(targetCount: targetCount,
                                                   maxSourcePages: maxSourcePages,
                                                   startingOffset: "",
                                                   startingPage: 1,
                                                   startingHasMore: true,
                                                   seenItemKeys: [])
        commit(result)
        return result.items
    }

    func loadMoreItems(targetCount: Int, maxSourcePages: Int) async throws -> [FeedFlowItem] {
        let result = try await loadMoreUntilTarget(targetCount: targetCount,
                                                   maxSourcePages: maxSourcePages,
                                                   startingOffset: lastOffset,
                                                   startingPage: nextPage,
                                                   startingHasMore: hasMore,
                                                   seenItemKeys: seenItemKeys)
        commit(result)
        return result.items
    }

    private func loadMoreUntilTarget(targetCount: Int,
                                     maxSourcePages: Int,
                                     startingOffset: String,
                                     startingPage: Int,
                                     startingHasMore: Bool,
                                     seenItemKeys: Set<String>) async throws -> LoadResult
    {
        guard startingHasMore else {
            return LoadResult(items: [],
                              lastOffset: startingOffset,
                              nextPage: startingPage,
                              hasMore: false,
                              seenItemKeys: seenItemKeys)
        }

        var pagesScanned = 0
        var accepted = [FeedFlowItem]()
        var resolvedOffset = startingOffset
        var resolvedPage = startingPage
        var resolvedHasMore = startingHasMore
        var resolvedSeenItemKeys = seenItemKeys

        while accepted.count < targetCount, pagesScanned < maxSourcePages, resolvedHasMore {
            try Task.checkCancellation()
            let requestedOffset = resolvedOffset
            let info = try await WebRequest.requestFollowsFeed(offset: resolvedOffset, page: resolvedPage)
            try Task.checkCancellation()
            pagesScanned += 1
            resolvedPage += 1
            resolvedOffset = info.offset
            resolvedHasMore = info.has_more && info.offset != requestedOffset

            let newItems = info.videoFeeds
                .compactMap(\.feedFlowItem)
                .filter { resolvedSeenItemKeys.insert($0.identityKey).inserted }
            accepted.append(contentsOf: newItems)
        }

        try Task.checkCancellation()
        return LoadResult(items: accepted,
                          lastOffset: resolvedOffset,
                          nextPage: resolvedPage,
                          hasMore: resolvedHasMore,
                          seenItemKeys: resolvedSeenItemKeys)
    }

    private func commit(_ result: LoadResult) {
        lastOffset = result.lastOffset
        nextPage = result.nextPage
        hasMore = result.hasMore
        seenItemKeys = result.seenItemKeys
    }
}
