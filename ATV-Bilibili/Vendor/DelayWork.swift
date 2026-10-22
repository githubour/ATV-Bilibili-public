//
//  DelayWork.swift
//  ATV-Bilibili
//
//  Created on 2025/11/27.
//

import Foundation

/// 延迟执行任务的工具类
/// 当有新任务时会自动取消前一个未完成的任务
@MainActor
class DelayWork {
    private var task: Task<Void, Never>?
    private let delay: TimeInterval
    private let noDelayForFirstTask: Bool

    /// 初始化延迟任务执行器
    /// - Parameter delay: 延迟时间 (秒)，默认 1 秒
    init(delay: TimeInterval = 1.0, noDelayForFirstTask: Bool = false) {
        self.delay = delay
        self.noDelayForFirstTask = noDelayForFirstTask
    }

    /// 提交一个延迟任务
    /// - Parameter work: 要执行的异步任务
    func submit(_ work: @escaping @MainActor () async throws -> Void) {
        // 立即路径也必须登记任务：此前这里直接 return 不给 task 赋值，task 恒为 nil，
        // 导致「每次 submit 都满足首次条件」——防抖完全失效（搜索联想曾每敲一键发一次请求），
        // 且立即执行的任务无法被后续 cancel。
        if task == nil, noDelayForFirstTask {
            task = Task { @MainActor in
                try? await work()
            }
            return
        }
        // 取消前一个未完成的任务
        task?.cancel()

        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                try await work()
            } catch {}
        }
    }

    /// 取消当前任务
    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
