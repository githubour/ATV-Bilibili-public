//
//  PlaybackQueuePolicyTests.swift
//  ATV-BilibiliTests
//

@testable import ATV_Bilibili
import AVFoundation
import XCTest

/// 连播来源策略：剧集/合集/主动队列可自动推进，推荐流/关注流播完即止。
final class PlaybackQueuePolicyTests: XCTestCase {
    func test_curatedQueuesAllowAutoAdvanceWhenMasterOn() {
        let kinds: [PlaybackQueueKind] = [.ugcCollection, .episodes, .manualSequence]
        for kind in kinds {
            XCTAssertTrue(
                SequenceAutoplayPolicy.shouldAutoAdvance(continuouslyPlay: true, kind: kind),
                "\(kind) 应该允许自动连播"
            )
        }
    }

    func test_feedsDoNotAutoAdvanceWhenMasterOn() {
        let kinds: [PlaybackQueueKind] = [.recommendationFeed, .followingFeed]
        for kind in kinds {
            XCTAssertFalse(
                SequenceAutoplayPolicy.shouldAutoAdvance(continuouslyPlay: true, kind: kind),
                "\(kind) 不应该自动连播"
            )
        }
    }

    func test_masterSwitchOffDisablesAllKinds() {
        let kinds: [PlaybackQueueKind] = [.ugcCollection, .episodes, .manualSequence, .recommendationFeed, .followingFeed]
        for kind in kinds {
            XCTAssertFalse(SequenceAutoplayPolicy.shouldAutoAdvance(continuouslyPlay: false, kind: kind))
        }
    }

    @MainActor
    func test_sequenceProviderKeepsKindAcrossAppend() {
        let provider = VideoSequenceProvider(
            seq: [PlayInfo(aid: 1, cid: 1)],
            currentIndex: 0,
            kind: .ugcCollection
        )
        XCTAssertEqual(provider.kind, .ugcCollection)

        provider.append([PlayInfo(aid: 2, cid: 2)])
        XCTAssertEqual(provider.count, 2)
        XCTAssertEqual(provider.kind, .ugcCollection)
    }

    @MainActor
    func test_feedQueueStopsAtEndAndEmitsPlayEnd() async {
        let provider = VideoSequenceProvider(
            seq: [PlayInfo(aid: 1, cid: 1), PlayInfo(aid: 2, cid: 2)],
            currentIndex: 0,
            kind: .recommendationFeed
        )
        let plugin = VideoPlayListPlugin(sequenceProvider: provider)
        var advancedInfo: PlayInfo?
        plugin.onPlayNextWithInfo = { advancedInfo = $0 }

        let ended = expectation(description: "feed queue 播完触发 onPlayEnd")
        plugin.onPlayEnd = { ended.fulfill() }
        plugin.playerDidEnd(player: AVPlayer())

        await fulfillment(of: [ended], timeout: 2)
        XCTAssertNil(advancedInfo)
        XCTAssertEqual(provider.currentIndex, 0)
    }

    @MainActor
    func test_collectionQueueAdvancesWhenContinuousPlayOn() async {
        let previous = Settings.continuouslyPlay
        Settings.continuouslyPlay = true
        defer { Settings.continuouslyPlay = previous }

        let provider = VideoSequenceProvider(
            seq: [PlayInfo(aid: 1, cid: 1), PlayInfo(aid: 2, cid: 2)],
            currentIndex: 0,
            kind: .ugcCollection
        )
        let plugin = VideoPlayListPlugin(sequenceProvider: provider)
        var advancedInfo: PlayInfo?
        plugin.onPlayNextWithInfo = { info in
            advancedInfo = info
        }

        plugin.playerDidEnd(player: AVPlayer())

        // moveNext 是异步的；让出主线程执行器直到 provider 推进或超时
        for _ in 0..<50 where advancedInfo == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(advancedInfo?.aid, 2)
        XCTAssertEqual(provider.currentIndex, 1)
    }
}
