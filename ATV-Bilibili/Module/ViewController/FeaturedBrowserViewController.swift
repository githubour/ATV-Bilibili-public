import Foundation
import UIKit

private extension ApiRequest.FeedResp.Items {
    func toFeaturedFeedFlowItem(durationLimit: FeaturedDurationLimit) -> FeedFlowItem? {
        guard goto == "av", can_play == 1 else { return nil }
        if Settings.featuredContentSafetyFilterEnabled,
           !FeaturedContentSafetyFilter.allows(feedItem: self)
        {
            return nil
        }

        let aidValue = Int(param) ?? player_args?.aid ?? 0
        let cidValue = player_args?.cid ?? 0
        let durationValue = player_args?.duration ?? 0
        guard aidValue > 0, cidValue > 0, durationValue > 0 else { return nil }
        if let maxDuration = durationLimit.maxDuration, durationValue > maxDuration {
            return nil
        }

        return FeedFlowItem(aid: aidValue,
                            cid: cidValue,
                            title: title,
                            ownerName: ownerName,
                            coverURL: pic,
                            avatarURL: avatar,
                            durationText: cover_right_text ?? TimeInterval(durationValue).timeString(),
                            viewCountText: cover_left_text_1 ?? "",
                            danmakuCountText: cover_left_text_2 ?? "",
                            reasonText: top_rcmd_reason ?? bottom_rcmd_reason)
    }
}

final class FeaturedBrowserViewController: FeedFlowBrowserViewController {
    init() {
        super.init(dataSource: FeaturedFeedFlowDataSource())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class FeaturedFeedFlowDataSource: FeedFlowDataSource {
    let title = "推荐"
    let defaultPreviewHintText = "停留后自动预览，按确认键进入短视频流"
    let loadingHintText = "正在加载沉浸式推荐..."
    let emptyStateText = "当前可播放的短视频较少，请稍后重试"
    let emptyHintText = "可以在设置里调整沉浸式视频时长上限"
    let loadFailureText = "推荐加载失败，请稍后重试"

    var reloadToken: String {
        "\(Settings.featuredDurationLimit.title)-\(Settings.featuredContentSafetyFilterEnabled)"
    }

    private var durationLimit = Settings.featuredDurationLimit
    private var lastSourceIdx: Int?
    private var seenItemKeys = Set<String>()
    private var hasMore = true

    private struct LoadResult {
        let items: [FeedFlowItem]
        let lastSourceIdx: Int?
        let hasMore: Bool
        let seenItemKeys: Set<String>
    }

    func reset() {
        durationLimit = Settings.featuredDurationLimit
        lastSourceIdx = nil
        seenItemKeys = []
        hasMore = true
    }

    func refreshFromStart(targetCount: Int, maxSourcePages: Int) async throws -> [FeedFlowItem] {
        let result = try await loadMoreUntilTarget(targetCount: targetCount,
                                                   maxSourcePages: maxSourcePages,
                                                   startingIdx: nil,
                                                   startingSeenKeys: [])
        lastSourceIdx = result.lastSourceIdx
        seenItemKeys = result.seenItemKeys
        hasMore = result.hasMore
        return result.items
    }

    func loadMoreItems(targetCount: Int, maxSourcePages: Int) async throws -> [FeedFlowItem] {
        guard hasMore else { return [] }
        let result = try await loadMoreUntilTarget(targetCount: targetCount,
                                                   maxSourcePages: maxSourcePages,
                                                   startingIdx: lastSourceIdx,
                                                   startingSeenKeys: seenItemKeys)
        lastSourceIdx = result.lastSourceIdx
        seenItemKeys = result.seenItemKeys
        hasMore = result.hasMore
        return result.items
    }

    /// 单循环凑够 targetCount: 起始游标与去重集合由调用方给定, 结束后一次性回写状态
    private func loadMoreUntilTarget(targetCount: Int,
                                     maxSourcePages: Int,
                                     startingIdx: Int?,
                                     startingSeenKeys: Set<String>) async throws -> LoadResult
    {
        let requestDurationLimit = durationLimit
        var accepted = [FeedFlowItem]()
        var pagesScanned = 0
        var resolvedIdx = startingIdx
        var resolvedSeenKeys = startingSeenKeys
        var reachedEnd = false

        while accepted.count < targetCount, pagesScanned < maxSourcePages, !reachedEnd {
            try Task.checkCancellation()
            let requestedSourceIdx = resolvedIdx
            let sourceItems = try await ApiRequest.getFeeds(lastIdx: resolvedIdx ?? 0)
            try Task.checkCancellation()
            pagesScanned += 1
            guard let pageLastIdx = sourceItems.last?.idx else {
                reachedEnd = true
                break
            }
            resolvedIdx = pageLastIdx
            accepted.append(contentsOf: sourceItems
                .compactMap { $0.toFeaturedFeedFlowItem(durationLimit: requestDurationLimit) }
                .filter { resolvedSeenKeys.insert($0.identityKey).inserted })
            if resolvedIdx == requestedSourceIdx {
                reachedEnd = true
                break
            }
        }

        try Task.checkCancellation()
        return LoadResult(items: accepted, lastSourceIdx: resolvedIdx, hasMore: !reachedEnd, seenItemKeys: resolvedSeenKeys)
    }
}
