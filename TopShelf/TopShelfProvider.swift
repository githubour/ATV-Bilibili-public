//
//  TopShelfProvider.swift
//  TopShelf
//
//  Top Shelf 扩展: 读取主 App 写入 App Group 的视频列表并展示。
//  支持双分区 (稍后再看在前, 最新动态在后);
//  点击(displayAction)进详情, 按播放键(playAction)直接起播。
//  注意扩展进程内存上限很低, 只做轻量读取, 图片由系统按 URL 拉取。
//

import Foundation
import os
import TVServices

class TopShelfProvider: TVTopShelfContentProvider {
    private struct ItemData: Codable {
        let aid: Int
        let title: String
        let cover: String
    }

    private struct SyncData: Codable {
        let toView: [ItemData]?
        let dynamic: [ItemData]?
        /// 向后兼容：老版本写入的 JSON 无此字段，Optional 解码为 nil → 该分区不渲染
        let history: [ItemData]?
    }

    override init() {
        super.init()
        // 用 default 级别(会落盘): info 级别不写日志库, 出问题在 log show 里完全查不到
        os_log("[topshelf] provider init", type: .default)
    }

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        os_log("[topshelf] loadTopShelfContent called", type: .default)
        // 扩展进程无 AppGroupId.swift(属于 App target), 直接读自身 Info.plist 注入值
        let suiteName = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String ?? ""
        guard !suiteName.isEmpty, let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: "topShelfItems")
        else {
            os_log("[topshelf] 读取共享区失败/无数据", type: .error)
            completionHandler(nil)
            return
        }
        let syncData: SyncData?
        do {
            syncData = try JSONDecoder().decode(SyncData.self, from: data)
        } catch {
            // 解码失败与无数据同表现, 但留日志便于排查字段结构变更
            os_log("[topshelf] decode failed: %{public}@", type: .error, String(describing: error))
            syncData = nil
        }
        guard let syncData else {
            completionHandler(nil)
            return
        }

        // 分区做 identifier 前缀: 同一视频同时出现在多个分区时避免重复 identifier。
        // 分区顺序即语义(无标题 API): 继续观看最前, 其次稍后再看, 最后动态。
        let sections: [(prefix: String, items: [ItemData])] = [
            ("history", syncData.history ?? []),
            ("toView", syncData.toView ?? []),
            ("dynamic", syncData.dynamic ?? []),
        ]
        let collections = sections
            .filter { !$0.items.isEmpty }
            .map { section in
                TVTopShelfItemCollection(items: section.items.map { makeItem(data: $0, sectionPrefix: section.prefix) })
            }

        guard !collections.isEmpty else {
            os_log("[topshelf] 两个分区都为空, 返回 nil", type: .error)
            completionHandler(nil)
            return
        }
        os_log("[topshelf] 返回 %d 个分区", type: .default, collections.count)
        completionHandler(TVTopShelfSectionedContent(sections: collections))
    }

    private func makeItem(data: ItemData, sectionPrefix: String) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: "\(sectionPrefix)-video-\(data.aid)")
        // B站封面本身就是 16:9 横图, 直接按 .hdtv 展示; 强行转 2:3 竖版会裁掉两侧主体
        item.imageShape = .hdtv
        item.setImageURL(coverURL(from: data.cover), for: [.screenScale1x, .screenScale2x])
        item.displayAction = TVTopShelfAction(url: URL(string: "bilibilitv://video?aid=\(data.aid)")!)
        item.playAction = TVTopShelfAction(url: URL(string: "bilibilitv://play?aid=\(data.aid)")!)
        return item
    }

    /// hdslb 图床支持「@宽w_高h_1c.格式」中心裁剪; 非 hdslb 或已带参数的 URL 原样返回。
    /// 协议相对地址与 http 一律升级 https: 扩展进程没有 ATS 例外, http 图片会加载失败。
    /// 用 jpg 而非 webp: topshelfd 图片加载官方仅承诺 PNG/JPEG, 实测同参数 jpg 可用。
    /// 960×540 对应 .hdtv 在 2x 屏上的展示尺寸, 再大只是白耗内存。
    private func coverURL(from cover: String) -> URL? {
        var urlStr = cover
        if urlStr.hasPrefix("//") { urlStr = "https:" + urlStr }
        else if urlStr.hasPrefix("http://") { urlStr = "https://" + urlStr.dropFirst("http://".count) }
        guard urlStr.contains("hdslb.com"), !urlStr.contains("@"),
              let url = URL(string: urlStr + "@960w_540h_1c.jpg")
        else { return URL(string: urlStr) }
        return url
    }
}
