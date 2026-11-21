//
//  MediaDownloadBudget.swift
//  ATV-Bilibili
//
//  全局媒体下载并发预算。只计数在途子请求数量, 不持有任何 CDN 排名/吞吐状态
//  (CDN 健康模型在 MediaRangeModels.swift, 逐会话有效)。
//
//  从 MediaRangeDownloader.swift 按职责拆出, 行为与原文件完全一致。
//

import Foundation

// MARK: - 全局并发预算（只管理资源数量，不持有 CDN 排名）

/// 所有活动媒体会话共享的总并发预算。
/// 只计数在途子请求数量，不记录任何 CDN 吞吐状态。
/// 许可与释放通过 BudgetPermit token 一一绑定：一次获取最多释放一次，
/// 未持许可的请求不得发送，避免绕过上限或重复释放破坏计数。
actor MediaDownloadBudget {
    static let shared = MediaDownloadBudget()

    /// 同时进行的全局请求上限（内部参数，实测调整）。
    private let globalMax = 12
    /// 同 host 上限（内部参数，实测调整）。
    private let perHostMax = 4

    /// 已发出的有效许可集合；释放时必须持有对应 token，否则忽略。
    private var outstanding = Set<BudgetPermit>()
    private var perHostActive = [String: Int]()

    /// 立即尝试获取许可；无槽位时返回 nil（由调用方有界等待后重试）。
    func tryAcquireNow(host: String) -> BudgetPermit? {
        guard outstanding.count < globalMax,
              (perHostActive[host] ?? 0) < perHostMax
        else { return nil }
        let permit = BudgetPermit(host: host)
        outstanding.insert(permit)
        perHostActive[host, default: 0] += 1
        return permit
    }

    /// 释放许可。同一 token 只生效一次；未知 token 直接忽略。
    func release(_ permit: BudgetPermit) {
        guard outstanding.remove(permit) != nil else { return }
        let host = permit.host
        if let current = perHostActive[host] {
            if current <= 1 {
                perHostActive[host] = nil
            } else {
                perHostActive[host] = current - 1
            }
        }
    }
}

/// 并发预算许可 token。一次获取、最多释放一次，不可伪造（仅预算 actor 可创建）。
struct BudgetPermit: Hashable, Sendable {
    /// 内部记账用的 host（URL host 小写形式）。
    let host: String
    private let id: UUID
    /// 仅 MediaDownloadBudget 可创建。
    fileprivate init(host: String) {
        self.host = host
        id = UUID()
    }
}
