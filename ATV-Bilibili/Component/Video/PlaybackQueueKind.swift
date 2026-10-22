//
//  PlaybackQueueKind.swift
//  ATV-Bilibili
//
//  连播队列的来源分类与自动推进策略。
//

import Foundation

/// 播放器里“下一集从哪来”的语义分类。
/// 自动连播只应该发生在剧集/合集/用户主动排的队列里，推荐流和关注流播完即止。
enum PlaybackQueueKind: Equatable {
    /// UP 主合集（ugc_season）
    case ugcCollection
    /// 番剧/影视分集、普通多 P 视频
    case episodes
    /// 长按列表后主动选择的“从此处顺序/倒序播放”
    case manualSequence
    /// 沉浸式「推荐」视频流
    case recommendationFeed
    /// 沉浸式「关注」视频流
    case followingFeed

    /// 队列本身是否具备“播完继续下一条”的语义。
    /// 注意这不是用户总开关，最终还要与 Settings.continuouslyPlay 合并判断。
    var allowsAutoAdvance: Bool {
        switch self {
        case .ugcCollection, .episodes, .manualSequence:
            return true
        case .recommendationFeed, .followingFeed:
            return false
        }
    }
}

enum SequenceAutoplayPolicy {
    /// 同时满足：用户打开连续播放 + 队列类型允许自动推进。
    static func shouldAutoAdvance(continuouslyPlay: Bool, kind: PlaybackQueueKind) -> Bool {
        continuouslyPlay && kind.allowsAutoAdvance
    }
}
