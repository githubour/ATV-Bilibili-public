//
//  MediaBytePipe.swift
//  ATV-Bilibili
//
//  有界字节通道: 异步生产者(下载器) → 同步消费者(HTTP writer)。
//  容量按字节限制, 满时生产者挂起; 不丢数据、不无限缓存。
//

import Foundation

// MARK: - 有界数据通道（异步生产者 → 同步 HTTP writer）

/// 私有桥接类型：只有下载器能写入已验证的有序字节，HTTP writer 在后台
/// socket 队列同步读取。容量按字节限制，满时生产者挂起（不阻塞线程）。
/// 禁止用无限缓存或丢弃旧数据实现背压；同一请求最多交付一次且严格递增。
final class MediaBytePipe: @unchecked Sendable {
    enum PipeError: Error {
        case closed
        case failed(Error)
        case readTimeout
    }

    private let condition = NSCondition()
    private var buffer = Data()
    private let capacityBytes: Int
    private var closed = false
    private var failure: Error?

    init(capacityBytes: Int = 2 * 1024 * 1024) {
        self.capacityBytes = max(64 * 1024, capacityBytes)
    }

    /// 异步写入。满时挂起直到消费者读取腾出空间；关闭/失败/取消时抛出。
    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let chunkEnd = min(data.count, offset + 256 * 1024)
            let chunk = data[offset..<chunkEnd]
            try await writeChunk(Data(chunk))
            offset = chunkEnd
        }
    }

    private func writeChunk(_ chunk: Data) async throws {
        if try tryAppend(chunk) { return }
        // 慢路径：等待空间（挂起让出线程，不阻塞线程池）。满管是加速模式的稳态
        // （下载快于播放消费），按 5ms→50ms 指数退避轮询，空转从 200 次/s 降到 ≤20 次/s
        var backoffNanoseconds: UInt64 = 5_000_000
        while true {
            try Task.checkCancellation()
            if try tryAppend(chunk) { return }
            try await Task.sleep(nanoseconds: backoffNanoseconds)
            backoffNanoseconds = min(backoffNanoseconds * 2, 50_000_000)
        }
    }

    /// 同步尝试追加；返回 true 表示已写入，false 表示缓冲满需稍后重试。
    /// 失败/关闭时直接抛出。锁操作封装在同步函数内，避免在 async 上下文直接调用。
    private func tryAppend(_ chunk: Data) throws -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if let failure {
            throw PipeError.failed(failure)
        }
        if closed {
            throw PipeError.closed
        }
        if buffer.count + chunk.count <= capacityBytes {
            buffer.append(chunk)
            condition.signal()
            return true
        }
        return false
    }

    /// 同步读取（供 Swifter writer 在后台队列调用，可阻塞该队列线程）。
    /// 返回 nil 表示 EOF（生产者已 close 且缓冲排空）。
    func readSync(maxLength: Int, timeout: TimeInterval = 30) throws -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while buffer.isEmpty {
            if let failure {
                throw PipeError.failed(failure)
            }
            if closed {
                return nil
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw PipeError.readTimeout
            }
            condition.wait(until: deadline)
        }
        let take = min(maxLength, buffer.count)
        let chunk = buffer.prefix(take)
        buffer.removeFirst(take)
        condition.signal()
        return Data(chunk)
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func fail(_ error: Error) {
        condition.lock()
        if failure == nil {
            failure = error
        }
        condition.broadcast()
        condition.unlock()
    }
}
