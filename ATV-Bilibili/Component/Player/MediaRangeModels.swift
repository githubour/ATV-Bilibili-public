//
//  MediaRangeModels.swift
//  ATV-Bilibili
//
//  Range 下载链路共用的数据模型: 传输上限、CDN 错误分类、host 健康统计、只读诊断快照。
//  这些类型被清单侧(降级判断)与下载器共同使用, 故独立成文件, 避免拆文件后互相依赖。
//

import Foundation

// MARK: - CDN 健康模型（当前媒体流内有效）

/// 跨层共用的传输上限：清单侧的降级判断必须与下载器实际肯接受的单请求上限一致，
/// 否则会出现「清单放行、下载器拒收」导致播放中断。
enum MediaDownloadLimits {
    /// 单个 Range 允许在内存中完整组装的字节上限
    static let singleRequestMemoryCap: Int64 = 16 * 1024 * 1024
}

enum CDNErrorCategory: Sendable {
    case timeout
    case serverError(status: Int)
    case forbidden
    case notFound
    case rangeNotSatisfiable
    case tooManyRequests
    case truncated
    case mismatch
    case network(Error)
    case cancelled
}

struct CDNHostStats: Sendable {
    var successCount = 0
    var failureCount = 0
    var consecutiveFailures = 0
    var totalBytes: Int64 = 0
    var totalTransferTime: TimeInterval = 0
    var lastTTFB: TimeInterval?
    var isolatedUntil: Date?

    var estimatedMbps: Double? {
        guard totalTransferTime > 0, totalBytes > 0 else { return nil }
        return Double(totalBytes) * 8 / totalTransferTime / 1_000_000
    }

    var isIsolated: Bool {
        if let until = isolatedUntil {
            return Date() < until
        }
        return false
    }
}

// MARK: - 只读诊断快照

struct MediaRangeDiagnostics: Sendable {
    var transportMode: MediaTransportMode
    var activeHosts: Int
    /// 各 host 历史实测吞吐之和：多 host 并行时近似聚合上限，单 host 时即其实测值。
    /// 它是估计值，不是端到端实测的聚合吞吐，不得直接作为性能验收的吞吐结论。
    var estimatedAggregateMbps: Double
    var activeSubrequests: Int
    var failures: Int
    var retries: Int
    var deliveredBytes: Int64
    var extraBytes: Int64
    var downgradedToDirect: Bool

    var redundancyRatio: Double {
        guard deliveredBytes > 0 else { return 0 }
        return Double(extraBytes) / Double(deliveredBytes)
    }
}
