//
//  TopShelfSyncManager.swift
//  ATV-Bilibili
//
//  拉取「动态/稍后再看」视频列表, 写入 App Group 共享存储,
//  供 Top Shelf 扩展进程读取展示 (支持双分区: 稍后再看 + 最新动态)。
//

import Foundation
import TVServices

struct TopShelfItemData: Codable {
    let aid: Int
    let title: String
    let cover: String
}

/// 写入共享存储的整体结构; 空分区不展示
struct TopShelfSyncData: Codable {
    var toView: [TopShelfItemData] = []
    var dynamic: [TopShelfItemData] = []
    /// 继续观看（看到一半的历史）。向后兼容：老版本写入的 JSON 无此字段时按空处理
    var history: [TopShelfItemData] = []
}

/// actor 化（2026-10-20）：此前是普通 class，lastRefresh/lastGoodData/refreshGeneration
/// 全裸奔——冷启动 SceneDelegate 与 BLTabBar 同时触发 refresh 时，两个并发 Task 都能
/// 通过节流检查（都读到旧值）而双双发起网络拉取。actor 天然串行化，节流检查原子。
actor TopShelfSyncManager {
    static let shared = TopShelfSyncManager()

    /// App Group 跟随构建注入的 bundle id (双版本各自隔离, 不再硬编码)
    static let appGroupID = AppGroupId.current
    static let storageKey = "topShelfItems"
    private static let maxItemCount = 20
    private static let refreshInterval: TimeInterval = 60 * 15

    private var lastRefresh = Date.distantPast
    /// 最近一次成功写入的数据; 某分区拉取失败时沿用旧数据, 避免一次网络抖动清空 Top Shelf
    private var lastGoodData = TopShelfSyncData()
    /// 自增代数, 只有最新一代的异步结果才允许写入, 丢弃乱序完成的旧任务
    private var refreshGeneration = 0
    private var lastWriteTime: Date?
    private var lastErrorText: String?

    /// 按设置刷新共享数据; throttle 避免频繁拉取
    /// （nonisolated 保持调用点无需 await，与旧行为一致）
    nonisolated func refresh(force: Bool = false) {
        Task { await self.refreshAndReport(force: force) }
    }

    /// 执行刷新并返回诊断文本(设置页"Top Shelf 数据诊断"展示)
    func refreshAndReport(force: Bool) async -> String {
        let source = Settings.topShelfSource
        guard source != .off, ApiRequest.isLogin() else {
            // 来源关闭或未登录: 清空共享数据, 避免旧账号的个人数据残留在主屏
            lastGoodData = TopShelfSyncData()
            write(TopShelfSyncData())
            return statusDescription
        }
        guard force || Date().timeIntervalSince(lastRefresh) > Self.refreshInterval else { return statusDescription }
        lastRefresh = Date()

        refreshGeneration += 1
        let generation = refreshGeneration

        var data = TopShelfSyncData()
        var anySuccess = false
        let sections = source.sections
        if sections.contains(.history) {
            do {
                data.history = try await fetchHistory()
                anySuccess = true
            } catch {
                Logger.warn("[topshelf] 继续观看拉取失败: \(error)")
                lastErrorText = "继续观看: \(Self.shortError(error))"
                data.history = lastGoodData.history
            }
        }
        if sections.contains(.toView) {
            do {
                data.toView = try await fetchToView()
                anySuccess = true
            } catch {
                Logger.warn("[topshelf] 稍后再看拉取失败: \(error)")
                lastErrorText = "稍后再看: \(Self.shortError(error))"
                data.toView = lastGoodData.toView
            }
        }
        if sections.contains(.dynamic) {
            do {
                data.dynamic = try await fetchDynamic()
                anySuccess = true
            } catch {
                Logger.warn("[topshelf] 动态拉取失败: \(error)")
                lastErrorText = "动态: \(Self.shortError(error))"
                data.dynamic = lastGoodData.dynamic
            }
        }
        // 已有更新的刷新发起, 或期间设置已切换: 丢弃本次结果
        guard generation == refreshGeneration, Settings.topShelfSource == source else { return statusDescription }
        // 全部失败: 不写入, 保留主屏现有内容
        if anySuccess {
            lastGoodData = data
            if data.toView.isEmpty == false || data.dynamic.isEmpty == false || data.history.isEmpty == false {
                lastErrorText = nil
            }
            write(data)
        }
        return statusDescription
    }

    /// 数据链路诊断: 登录态/来源/共享区实际内容(扩展进程读取的即此数据)/最近写入与错误
    /// （actor 隔离：只在本类型内部同步调用，外部经 refreshAndReport 拿到）
    private var statusDescription: String {
        var parts: [String] = []
        parts.append(ApiRequest.isLogin() ? "已登录" : "未登录")
        parts.append("来源:\(Settings.topShelfSource.title)")
        if let data = UserDefaults(suiteName: Self.appGroupID)?.data(forKey: Self.storageKey),
           let sync = try? JSONDecoder().decode(TopShelfSyncData.self, from: data)
        {
            parts.append("共享区: 稍后再看\(sync.toView.count)条·动态\(sync.dynamic.count)条·继续观看\(sync.history.count)条")
        } else {
            parts.append("共享区: 无数据")
        }
        if let lastWriteTime {
            parts.append("写入于\(DateFormatter.clockTime.string(from: lastWriteTime))")
        }
        if let lastErrorText {
            parts.append("最近错误:\(lastErrorText)")
        }
        return parts.joined(separator: "；")
    }

    private static func shortError(_ error: Error) -> String {
        String(String(describing: error).prefix(60))
    }

    private func fetchToView() async throws -> [TopShelfItemData] {
        let list = try await WebRequest.requestToView()
        return list.prefix(Self.maxItemCount).compactMap { item -> TopShelfItemData? in
            // 无封面的条目在扩展侧只能渲染灰色占位, 直接过滤
            guard let pic = item.pic, !pic.absoluteString.isEmpty else { return nil }
            return TopShelfItemData(aid: item.aid,
                                    title: item.title,
                                    cover: pic.absoluteString)
        }
    }

    private func fetchDynamic() async throws -> [TopShelfItemData] {
        // 直接复用「关注」tab 的拉取: 同接口同参数同解码模型, 保证 Top Shelf 与 App 内展示一致
        let info = try await WebRequest.requestFollowsFeed(offset: "", page: 1)
        return info.videoFeeds.prefix(Self.maxItemCount).compactMap { feed -> TopShelfItemData? in
            guard feed.aid > 0, let cover = feed.pic, !cover.absoluteString.isEmpty else { return nil }
            return TopShelfItemData(aid: feed.aid,
                                    title: feed.title,
                                    cover: cover.absoluteString)
        }
    }

    private func fetchHistory() async throws -> [TopShelfItemData] {
        // 继续观看 = 已开始但未看完的历史；progress/duration 单位为毫秒，progress<=0 表示未真正观看
        let list = try await WebRequest.requestHistory()
        return list
            .filter { $0.progress > 0 && ($0.duration <= 0 || $0.progress < $0.duration) }
            .prefix(Self.maxItemCount)
            .compactMap { item -> TopShelfItemData? in
                guard let pic = item.pic, !pic.absoluteString.isEmpty else { return nil }
                return TopShelfItemData(aid: item.aid,
                                        title: item.title,
                                        cover: pic.absoluteString)
            }
    }

    private func write(_ data: TopShelfSyncData) {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID) else {
            Logger.warn("[topshelf] 无法访问 App Group \(Self.appGroupID)")
            return
        }
        if let encoded = try? JSONEncoder().encode(data) {
            defaults.set(encoded, forKey: Self.storageKey)
            // 写后立刻通知扩展进程跨进程读取, synchronize 消除偶发读到旧值的窗口
            defaults.synchronize()
            lastWriteTime = Date()
        }
        TVTopShelfContentProvider.topShelfContentDidChange()
        Logger.debug("[topshelf] 已写入 继续观看:\(data.history.count) 稍后再看:\(data.toView.count) 动态:\(data.dynamic.count)")
    }
}
