//
//  KeychainStoreTests.swift
//  ATV-BilibiliTests
//

@testable import ATV_Bilibili
import XCTest

final class KeychainStoreTests: XCTestCase {
    /// 每次运行随机 key，避免与宿主 App 或历史残留条目冲突
    private let key = "test.keychain.\(UUID().uuidString)"

    override func tearDown() {
        KeychainStore.removeData(forKey: key)
        super.tearDown()
    }

    func testReadMissingKeyReturnsNil() {
        XCTAssertNil(KeychainStore.data(forKey: key))
    }

    func testSetGetRoundtrip() {
        let payload = Data("token+SESSDATA".utf8)
        KeychainStore.setData(payload, forKey: key)
        XCTAssertEqual(KeychainStore.data(forKey: key), payload)
    }

    func testSetOverwritesExistingValue() {
        KeychainStore.setData(Data("old".utf8), forKey: key)
        let newPayload = Data("new".utf8)
        KeychainStore.setData(newPayload, forKey: key)
        XCTAssertEqual(KeychainStore.data(forKey: key), newPayload)
    }

    func testRemoveData() {
        KeychainStore.setData(Data("x".utf8), forKey: key)
        KeychainStore.removeData(forKey: key)
        XCTAssertNil(KeychainStore.data(forKey: key))
    }
}
