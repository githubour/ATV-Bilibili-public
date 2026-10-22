//
//  MediaRangeParsingTests.swift
//  ATV-BilibiliTests
//
//  Range/Content-Range 纯函数回归：这是播放器代理层最容易在边界上出错的逻辑。
//

@testable import ATV_Bilibili
import XCTest

final class MediaRangeParsingTests: XCTestCase {
    private func range(_ header: String?, length: Int64?) -> ParsedMediaRange {
        MediaRangeParsing.parse(header: header, fileLength: length)
    }

    func testMissingHeaderIsMissing() {
        XCTAssertEqual(range(nil, length: 100), .missing)
        XCTAssertEqual(range("   ", length: 100), .missing)
    }

    func testSingleClosedRange() throws {
        let parsed = range("bytes=0-99", length: 100)
        guard case let .single(value) = parsed else { return XCTFail("应解析为 single") }
        XCTAssertEqual(value.start, 0)
        XCTAssertEqual(value.end, 99)
        XCTAssertEqual(value.length, 100)
    }

    func testOpenEndedWithKnownLength() throws {
        let parsed = range("bytes=10-", length: 100)
        guard case let .single(value) = parsed else { return XCTFail("应归一化为 single") }
        XCTAssertEqual(value.start, 10)
        XCTAssertEqual(value.end, 99)
    }

    func testSuffixRangeUsesTail() throws {
        let parsed = range("bytes=-20", length: 100)
        guard case let .single(value) = parsed else { return XCTFail("应归一化为 single") }
        XCTAssertEqual(value.start, 80)
        XCTAssertEqual(value.end, 99)
    }

    func testSuffixClampsToFileLength() throws {
        let parsed = range("bytes=-200", length: 100)
        guard case let .single(value) = parsed else { return XCTFail("应归一化为 single") }
        XCTAssertEqual(value.start, 0)
        XCTAssertEqual(value.end, 99)
    }

    func testUnboundedWithoutLengthStaysOpen() {
        XCTAssertEqual(range("bytes=10-", length: nil), .openEnded(start: 10))
        XCTAssertEqual(range("bytes=-20", length: nil), .suffix(length: 20))
    }

    func testMultiRangeRejected() {
        XCTAssertEqual(range("bytes=0-1,3-4", length: 100), .multiUnsupported)
    }

    func testInvalidSyntaxRejected() {
        XCTAssertEqual(range("items=0-1", length: 100), .invalid)
        XCTAssertEqual(range("bytes=a-b", length: 100), .invalid)
        XCTAssertEqual(range("bytes=1", length: 100), .invalid)
        XCTAssertEqual(range("bytes=0-10-20", length: 100), .invalid)
    }

    func testOutOfBoundsRejected() {
        XCTAssertEqual(range("bytes=100-", length: 100), .unsatisfiable(total: 100))
        XCTAssertEqual(range("bytes=0-100", length: 100), .unsatisfiable(total: 100))
        XCTAssertEqual(range("bytes=-1", length: 0), .unsatisfiable(total: 0))
    }

    func testContentRange() throws {
        let parsed = MediaRangeParsing.parseContentRange("bytes 0-1023/4096")
        XCTAssertEqual(parsed?.range.start, 0)
        XCTAssertEqual(parsed?.range.end, 1023)
        XCTAssertEqual(parsed?.total, 4096)

        let unknown = MediaRangeParsing.parseContentRange("bytes 5-9/*")
        XCTAssertEqual(unknown?.range.start, 5)
        XCTAssertEqual(unknown?.range.end, 9)
        XCTAssertNil(unknown?.total)
    }

    func testContentRangeRejectsGarbage() {
        XCTAssertNil(MediaRangeParsing.parseContentRange(""))
        XCTAssertNil(MediaRangeParsing.parseContentRange("items 0-1/2"))
        XCTAssertNil(MediaRangeParsing.parseContentRange("bytes 1-0/2"))
        XCTAssertNil(MediaRangeParsing.parseContentRange("bytes 0-1"))
    }
}
