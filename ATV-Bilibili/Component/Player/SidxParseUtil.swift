//
//  SidxParseUtil.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/11/13.
//

import Foundation

enum SidxParseUtil {
    struct Sidx {
        let timescale: Int
        let firstOffset: Int
        let earliestPresentationTime: Int
        let segments: [SegmentInfo]

        struct SegmentInfo {
            let type: Int
            let size: Int
            let duration: Int
            let sap: Int
            let sap_type: Int
            let sap_delta: Int
        }

        func maxSegmentDuration() -> Int? {
            if let duration = segments.map({ Double($0.duration) / Double(timescale) }).max() {
                return Int(duration + 1)
            }
            return nil
        }
    }

    static func processIndexData(data: Data) -> Sidx? {
        var offset: UInt64 = 0
        var sidx: Sidx?
        // 用加法写法避免 data.count < 8 时的 Int 下溢 trap，同时保证头部 8 字节读取不越界
        while offset + 8 <= UInt64(data.count) {
            var size = UInt64(data.getUint32(offset: &offset))
            let typeArr = data.getUint32(offset: &offset).toUInt8s
            guard let typeString = String(bytes: typeArr, encoding: .utf8) else { return nil }
            if size == 1 {
                // 64 位扩展长度本身占 8 字节，读取前校验边界
                guard offset + 8 <= UInt64(data.count) else { return nil }
                size = data.getValue(type: UInt64.self, offset: &offset)
            }
            // size 含 8 字节头；防御 0/负值下的 UInt64 下溢与超 Int.max 的转换 trap
            guard size >= 8, size <= UInt64(Int.max) else { return nil }
            switch typeString {
            case "sidx":
                // size includes the 8-byte header (4 size + 4 type)
                let boxDataSize = Int(size) - 8
                let endIndex = Int(offset) + boxDataSize

                guard endIndex <= data.count else {
                    return nil
                }

                guard let parsed = processSIDX(data: Data(data[Int(offset)..<endIndex])) else { return nil }
                sidx = parsed
                offset += UInt64(boxDataSize)
            default:
                offset += (size - 8)
            }
        }
        return sidx
    }

    private static func processSIDX(data: Data) -> Sidx? {
        var offset: UInt64 = 0
        func readUint8() -> UInt8? { data.getUint8IfPresent(offset: &offset) }
        func readUint32() -> UInt32? { data.getUint32IfPresent(offset: &offset) }
        func readUint16BE() -> UInt16? { data.getValueIfPresent(type: UInt16.self, offset: &offset).map(\.bigEndian) }
        func readUint64BE() -> UInt64? { data.getValueIfPresent(type: UInt64.self, offset: &offset).map(\.bigEndian) }

        guard let version = readUint8(),
              readUint8() != nil, readUint8() != nil, readUint8() != nil, // none
              readUint32() != nil, // refID
              let timescale = readUint32()
        else { return nil }

        // version 0: 32-bit, version 1: 64-bit
        let earliest_presentation_time: UInt64
        let first_offset: UInt64
        if version == 0 {
            guard let e = readUint32(), let f = readUint32() else { return nil }
            earliest_presentation_time = UInt64(e)
            first_offset = UInt64(f)
        } else {
            guard let e = readUint64BE(), let f = readUint64BE() else { return nil }
            earliest_presentation_time = e
            first_offset = f
        }

        guard readUint16BE() != nil, // reversed
              let reference_count = readUint16BE()
        else { return nil }

        var infos = [Sidx.SegmentInfo]()
        for _ in 0..<reference_count {
            guard let code = readUint32(),
                  let duration = readUint32(),
                  let sapCode = readUint32()
            else { return nil }
            let reference_type = (code >> 31) & 1
            let referenced_size = (code & 0x7fffffff)
            let starts_with_SAP = (sapCode >> 31) & 1
            let sap_type = (sapCode >> 29) & 7
            let sap_delta_time = (sapCode & 0x0fffffff)
            let info = Sidx.SegmentInfo(type: Int(reference_type), size: Int(referenced_size), duration: Int(duration), sap: Int(starts_with_SAP), sap_type: Int(sap_type), sap_delta: Int(sap_delta_time))
            infos.append(info)
        }

        return Sidx(timescale: Int(timescale), firstOffset: Int(first_offset), earliestPresentationTime: Int(earliest_presentation_time), segments: infos)
    }
}

extension Data {
    func getUint32(offset: inout UInt64) -> UInt32 {
        getValue(type: UInt32.self, offset: &offset).bigEndian
    }

    func getUint8(offset: inout UInt64) -> UInt8 {
        getValue(type: UInt8.self, offset: &offset).bigEndian
    }

    func getValue<T>(type: T.Type, offset: inout UInt64) -> T {
        let size = UInt64(MemoryLayout<T>.size)
        defer {
            offset += size
        }
        return Data(self[offset..<size + offset]).withUnsafeBytes({ $0.load(as: T.self) })
    }

    /// 边界安全读取：越界返回 nil 且不推进 offset（畸形 sidx 载荷防护）
    func getValueIfPresent<T>(type: T.Type, offset: inout UInt64) -> T? {
        let size = UInt64(MemoryLayout<T>.size)
        guard offset + size <= UInt64(count) else { return nil }
        defer {
            offset += size
        }
        return Data(self[offset..<size + offset]).withUnsafeBytes({ $0.load(as: T.self) })
    }

    func getUint32IfPresent(offset: inout UInt64) -> UInt32? {
        getValueIfPresent(type: UInt32.self, offset: &offset)?.bigEndian
    }

    func getUint8IfPresent(offset: inout UInt64) -> UInt8? {
        getValueIfPresent(type: UInt8.self, offset: &offset)?.bigEndian
    }
}

protocol UIntToUInt8sConvertable {
    var toUInt8s: [UInt8] { get }
}

extension UIntToUInt8sConvertable {
    func toUInt8Arr<T>(endian: T, count: Int) -> [UInt8] {
        var _endian = endian
        let UInt8Ptr = withUnsafePointer(to: &_endian) {
            $0.withMemoryRebound(to: UInt8.self, capacity: count) {
                UnsafeBufferPointer(start: $0, count: count)
            }
        }
        return [UInt8](UInt8Ptr)
    }
}

extension UInt32: UIntToUInt8sConvertable {
    var toUInt8s: [UInt8] {
        return toUInt8Arr(endian: bigEndian,
                          count: MemoryLayout<UInt32>.size)
    }
}

extension UInt64: UIntToUInt8sConvertable {
    var toUInt8s: [UInt8] {
        return toUInt8Arr(endian: bigEndian,
                          count: MemoryLayout<UInt64>.size)
    }
}
