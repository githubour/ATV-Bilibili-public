//
//  InFlightPool.swift
//  ATV-Bilibili
//
//  PlayContextCache / PlayerMediaWarmupManager / SidxDownloader 三个缓存 actor
//  共用的并发脚手架原语。
//
//  设计说明：三者的「结果落地策略」语义各不相同（快照缓存+选择性trim、waiter-wins、
//  nil失败不缓存且淘汰时取消在途任务），强行合并成单个泛型池需要五六个策略钩子，
//  等价性反而更难保证；因此只收敛真正逐字相同的部分——LRU 触达簿记与 in-flight
//  token 条目，各 actor 保留自己的落地策略。
//

import Foundation

/// 规范化的 LRU 触达顺序：touch 移到队尾，淘汰从队首取。
/// 取代三个缓存 actor 各自维护的 accessOrder 数组 + removeAll 样板。
struct LRUOrder<Key: Hashable> {
    private var keys: [Key] = []

    /// 触达一次（移到最新位置）
    mutating func touch(_ key: Key) {
        keys.removeAll { $0 == key }
        keys.append(key)
    }

    mutating func remove(_ key: Key) {
        keys.removeAll { $0 == key }
    }

    mutating func clear() {
        keys.removeAll()
    }

    /// 取最旧的一个并移出队列；无 key 时返回 nil
    mutating func popOldest() -> Key? {
        keys.isEmpty ? nil : keys.removeFirst()
    }

    /// 只保留集合内的 key（选择性清理）
    mutating func keep(only kept: Set<Key>) {
        keys.removeAll { !kept.contains($0) }
    }

    /// 最新的 n 个 key（按新→旧排列）
    func mostRecent(_ n: Int) -> [Key] {
        Array(keys.reversed().prefix(n))
    }
}

/// in-flight 去重条目：结果落地前用 token 校验「这条任务仍是当前登记的那条」，
/// 防止已被 trim 淘汰或替换的旧任务结果错误写入缓存。
struct InFlight<Success, Failure: Error> {
    let token = UUID()
    let task: Task<Success, Failure>
}
