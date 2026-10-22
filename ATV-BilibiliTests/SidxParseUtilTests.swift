//
//  SidxParseUtilTests.swift
//  ATV-BilibiliTests
//
//  DASH sidx 纯解析：边界/64 位 size/参考项字段。
//

@testable import ATV_Bilibili
import XCTest

final class SidxParseUtilTests: XCTestCase {
    private func be16(_ value: UInt16) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private func be32(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private func be64(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private func sidxPayload(timescale: UInt32 = 1000,
                             earliest: UInt32 = 0,
                             firstOffset: UInt32 = 0,
                             references: [(size: UInt32, duration: UInt32, sap: UInt32)]) -> [UInt8]
    {
        var bytes = [UInt8]()
        bytes += [0, 0, 0, 0] // version 0 + flags
        bytes += be32(1) // reference_ID
        bytes += be32(timescale)
        bytes += be32(earliest)
        bytes += be32(firstOffset)
        bytes += be16(0) // reserved
        bytes += be16(UInt16(references.count))
        for ref in references {
            bytes += be32(ref.size)
            bytes += be32(ref.duration)
            bytes += be32(ref.sap)
        }
        return bytes
    }

    private func box32(_ payload: [UInt8]) -> Data {
        Data(be32(UInt32(payload.count + 8)) + Array("sidx".utf8) + payload)
    }

    private func box64(_ payload: [UInt8]) -> Data {
        Data([0, 0, 0, 1] + Array("sidx".utf8) + be64(UInt64(payload.count + 16)) + payload)
    }

    func testParsesReferencesAndTimescale() throws {
        let payload = sidxPayload(timescale: 1000,
                                  earliest: 12,
                                  firstOffset: 34,
                                  references: [
                                      (size: 0x80000000 | 100, duration: 500, sap: 0x90000000),
                                      (size: 200, duration: 1500, sap: 0),
                                  ])
        let parsed = try XCTUnwrap(SidxParseUtil.processIndexData(data: box32(payload)))
        XCTAssertEqual(parsed.timescale, 1000)
        XCTAssertEqual(parsed.earliestPresentationTime, 12)
        XCTAssertEqual(parsed.firstOffset, 34)
        XCTAssertEqual(parsed.segments.count, 2)
        XCTAssertEqual(parsed.segments[0].type, 1)
        XCTAssertEqual(parsed.segments[0].size, 100)
        XCTAssertEqual(parsed.segments[0].sap, 1)
        XCTAssertEqual(parsed.segments[1].size, 200)
        XCTAssertEqual(parsed.maxSegmentDuration(), 2) // 1500/1000 = 1.5 -> Int(1.5 + 1) = 2
    }

    func testParses64BitBoxSize() throws {
        let payload = sidxPayload(timescale: 90000,
                                  references: [(size: 10, duration: 3000, sap: 0)])
        // 旧实现按 8 字节头计算会多读 8 字节，导致 endIndex 越界返回 nil。
        let parsed = try XCTUnwrap(SidxParseUtil.processIndexData(data: box64(payload)))
        XCTAssertEqual(parsed.timescale, 90000)
        XCTAssertEqual(parsed.segments.count, 1)
    }

    func testTruncatedPayloadReturnsNil() {
        let payload = sidxPayload(references: [(size: 10, duration: 1, sap: 0)])
        var data = box32(payload)
        data.removeLast(4)
        XCTAssertNil(SidxParseUtil.processIndexData(data: data))
    }

    func testEmptyOrGarbageReturnsNil() {
        XCTAssertNil(SidxParseUtil.processIndexData(data: Data()))
        XCTAssertNil(SidxParseUtil.processIndexData(data: Data([0, 0, 0, 8, 0x66, 0x72, 0x65, 0x65])))
    }
}
