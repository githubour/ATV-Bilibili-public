//
//  PlaySpeed.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2024/5/25.
//

import Foundation

/// 播放倍速选项。原先挂在 SpeedChangerPlugin.swift（该文件 import AVKit）尾部，
/// 导致 Settings 引用倍速模型时被播放器框架绑死；独立成文件后只依赖 Foundation。
struct PlaySpeed: Codable {
    var name: String
    var value: Float
}

extension PlaySpeed: Equatable {
    static let `default` = PlaySpeed(name: "1X", value: 1)

    static let blDefaults = [
        PlaySpeed(name: "0.5X", value: 0.5),
        PlaySpeed(name: "0.75X", value: 0.75),
        PlaySpeed(name: "1X", value: 1),
        PlaySpeed(name: "1.25X", value: 1.25),
        PlaySpeed(name: "1.5X", value: 1.5),
        PlaySpeed(name: "1.75X", value: 1.75),
        PlaySpeed(name: "2X", value: 2),
    ]
}
