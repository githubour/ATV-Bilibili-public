//
//  EpisodeEntry.swift
//  ATV-Bilibili
//
//  播放器内「选集」的一条。番剧分集与普通多 P 在详情页已统一映射成 [PlayInfo]，
//  这里只补上展示用的标题/集数文案/封面，不再引入第二套播放序列模型。
//

import Foundation

struct EpisodeEntry: Hashable {
    /// 展示标题（番剧为 "集数 标题"，多 P 为 part 名）
    let title: String
    /// 卡片左上角叠加的集数文案，如 "1" / "P1"
    let indexText: String
    /// 官方 TV 版各分集卡用的是同一张海报，这里统一取视频封面，避免逐集额外请求
    let coverURL: URL?
    let playInfo: PlayInfo
    let sequenceIndex: Int
}

extension EpisodeEntry {
    /// 从播放序列构建选集列表。isBangumi 决定集数文案用「N」还是「PN」。
    static func build(from playSeq: [PlayInfo],
                      isBangumi: Bool,
                      coverURL: URL?) -> [EpisodeEntry]
    {
        playSeq.enumerated().map { index, info in
            let indexText = isBangumi ? "\(index + 1)" : "P\(index + 1)"
            // 番剧的 title 本身就带集数（详情页按 title + long_title 拼的 part），不要再前缀一次编号
            let name = info.title ?? ""
            let title = name.isEmpty ? indexText : name
            return EpisodeEntry(title: title,
                                indexText: indexText,
                                coverURL: info.coverURL ?? coverURL,
                                playInfo: info,
                                sequenceIndex: index)
        }
    }
}
