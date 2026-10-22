//
//  WbiSignTests.swift
//  ATV-BilibiliTests
//

@testable import ATV_Bilibili
import XCTest

final class WbiSignTests: XCTestCase {
    /// 恰好 64 字符的 orig（策略制定者用 mixinKeyEncTab 逐位复核过的金标准向量）
    private static let goldenOrig = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ!@"

    func test_mixinKeyGoldenVector() {
        XCTAssertEqual(WbiCrypto.deriveMixinKey(Self.goldenOrig), "KLi2R8nwfOavW3JzrH5Nx9GjtseDcCFd")
    }

    func test_md5KnownVector() {
        // 公开已知 MD5("abc")，双重验证
        XCTAssertEqual(WbiCrypto.md5Hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
    }

    func test_encWbi_shapeOnly() {
        let result = WbiCrypto.encWbi(params: ["b": "2", "a": "1"], imgKey: "0123456789abcdef0123456789abcdef", subKey: "fedcba9876543210fedcba9876543210")
        // (a) 追加 wts 且为 Int
        let wts = result["wts"] as? Int
        XCTAssertNotNil(wts, "wts 应为 Int 时间戳")
        // (b) 追加 w_rid 且为 32 位小写十六进制
        let wrid = result["w_rid"] as? String
        XCTAssertNotNil(wrid)
        XCTAssertNotNil(wrid?.range(of: "^[0-9a-f]{32}$", options: .regularExpression),
                        "w_rid 应为 32 位小写十六进制: \(wrid ?? "nil")")
        // (c) 原 params 的键仍在（追加语义，不是替换）
        XCTAssertEqual(result["a"] as? String, "1")
        XCTAssertEqual(result["b"] as? String, "2")
    }

    func test_escapeQueryValue_preservesSignatureFormat() {
        XCTAssertEqual(WbiCrypto.escapeQueryValue("a&b"), "a%26b")
        XCTAssertEqual(WbiCrypto.escapeQueryValue("a+b"), "a%2Bb")
        XCTAssertEqual(WbiCrypto.escapeQueryValue("a=b"), "a%3Db")
        XCTAssertEqual(WbiCrypto.escapeQueryValue("a#b"), "a%23b")
        // 中文/空格维持现状（由 URL 构造阶段处理），不改变既有签名行为
        XCTAssertEqual(WbiCrypto.escapeQueryValue("中文 词"), "中文 词")
    }

    func test_encWbi_filtersSpecialCharactersInValues() {
        // 实现会对值过滤 !'()*——用同一签名结果固化该行为
        let filtered = WbiCrypto.encWbi(params: ["a": "va!(lu)e*"], imgKey: Self.goldenOrig, subKey: Self.goldenOrig)
        let plain = WbiCrypto.encWbi(params: ["a": "value"], imgKey: Self.goldenOrig, subKey: Self.goldenOrig)
        XCTAssertEqual(filtered["w_rid"] as? String, plain["w_rid"] as? String,
                       "值里的 !'()* 应被过滤后再签名")
    }
}
