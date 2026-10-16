//
//  DisplayOverlay+Factory.swift
//  ATV-Bilibili
//
//  收敛各模型里重复的 overlay 构造（播放数 / 弹幕数 / 时长）。
//

import Foundation

extension DisplayOverlay {
    private static let playIcon = "play.rectangle"
    private static let danmakuIcon = "list.bullet.rectangle"

    private static func item(_ icon: String?, value: Int?) -> DisplayOverlayItem? {
        guard let value else { return nil }
        return DisplayOverlayItem(icon: icon, text: value == 0 ? "-" : value.numberString())
    }

    private static func item(_ icon: String?, text: String?) -> DisplayOverlayItem? {
        guard let text, !text.isEmpty else { return nil }
        return DisplayOverlayItem(icon: icon, text: text == "0" ? "-" : text)
    }

    /// 视频卡片 overlay：左播放数 + 弹幕数，右时长。
    /// 计数为 nil 时省略该项，为 0 时显示 "-"。
    static func video(play: Int?, danmaku: Int?, durationText: String?) -> DisplayOverlay {
        let leftItems = [item(playIcon, value: play), item(danmakuIcon, value: danmaku)].compactMap { $0 }
        let rightItems = [item(nil, text: durationText)].compactMap { $0 }
        return DisplayOverlay(leftItems: leftItems, rightItems: rightItems)
    }

    /// 计数以字符串形式返回的接口（如动态流）用这个重载
    static func video(playText: String?, danmakuText: String?, durationText: String?) -> DisplayOverlay {
        let leftItems = [item(playIcon, text: playText), item(danmakuIcon, text: danmakuText)].compactMap { $0 }
        let rightItems = [item(nil, text: durationText)].compactMap { $0 }
        return DisplayOverlay(leftItems: leftItems, rightItems: rightItems)
    }
}
