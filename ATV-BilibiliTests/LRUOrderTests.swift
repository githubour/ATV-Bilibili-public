//
//  LRUOrderTests.swift
//  ATV-BilibiliTests
//

@testable import ATV_Bilibili
import XCTest

final class LRUOrderTests: XCTestCase {
    func test_touchRefreshesRecency() {
        var lru = LRUOrder<String>()
        lru.touch("a")
        lru.touch("b")
        lru.touch("c")
        XCTAssertEqual(lru.popOldest(), "a")
        lru.touch("a")
        // a 被重新触达后，最旧变成 b
        XCTAssertEqual(lru.popOldest(), "b")
    }

    func test_popOldestDrainsInOldestFirstOrder() {
        var lru = LRUOrder<String>()
        ["x", "y", "z"].forEach { lru.touch($0) }
        XCTAssertEqual(lru.popOldest(), "x")
        XCTAssertEqual(lru.popOldest(), "y")
        XCTAssertEqual(lru.popOldest(), "z")
        XCTAssertNil(lru.popOldest())
    }

    func test_removeAndClear() {
        var lru = LRUOrder<String>()
        lru.touch("a")
        lru.touch("b")
        lru.remove("a")
        XCTAssertEqual(lru.popOldest(), "b")
        XCTAssertNil(lru.popOldest())

        lru.touch("c")
        lru.clear()
        XCTAssertNil(lru.popOldest())
    }

    func test_touchSameKeyDoesNotDuplicate() {
        var lru = LRUOrder<String>()
        lru.touch("a")
        lru.touch("a")
        XCTAssertEqual(lru.popOldest(), "a")
        XCTAssertNil(lru.popOldest(), "重复 touch 不应产生重复条目")
    }

    func test_keepOnly() {
        var lru = LRUOrder<String>()
        lru.touch("a")
        lru.touch("b")
        lru.touch("c")
        lru.keep(only: ["a", "c"])
        XCTAssertEqual(lru.popOldest(), "a")
        XCTAssertEqual(lru.popOldest(), "c")
        XCTAssertNil(lru.popOldest())
    }

    func test_mostRecent() {
        var lru = LRUOrder<String>()
        lru.touch("a")
        lru.touch("b")
        lru.touch("c")
        XCTAssertEqual(lru.mostRecent(2), ["c", "b"])
        XCTAssertEqual(lru.mostRecent(10), ["c", "b", "a"])
        XCTAssertEqual(lru.mostRecent(0), [])
    }
}
