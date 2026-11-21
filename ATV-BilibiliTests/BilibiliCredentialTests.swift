//
//  BilibiliCredentialTests.swift
//  ATV-BilibiliTests
//
//  凭据配置化后的回落规则：未配置时必须是公开 TV 端常量，
//  配置了（Info.plist 注入 / 构建变量）就原样采用。
//

@testable import ATV_Bilibili
import XCTest

final class BilibiliCredentialTests: XCTestCase {
    func testResolveFallsBackWhenMissing() {
        XCTAssertEqual(BilibiliCredential.resolve(value: nil, fallback: "fallback"), "fallback")
    }

    func testResolveFallsBackWhenBlank() {
        XCTAssertEqual(BilibiliCredential.resolve(value: "", fallback: "fallback"), "fallback")
        XCTAssertEqual(BilibiliCredential.resolve(value: "   \n ", fallback: "fallback"), "fallback")
    }

    /// Info.plist 里的 $(VAR) 没被构建变量替换时会留下字面量，必须当作未配置
    func testResolveTreatsUnexpandedBuildSettingAsMissing() {
        XCTAssertEqual(BilibiliCredential.resolve(value: "$(BILIBILI_APPKEY)", fallback: "fallback"),
                       "fallback")
    }

    func testResolveKeepsConfiguredValueTrimmed() {
        XCTAssertEqual(BilibiliCredential.resolve(value: "  mykey123  ", fallback: "fallback"),
                       "mykey123")
    }

    func testEffectiveCredentialsAreNeverEmpty() {
        XCTAssertFalse(ApiRequest.appkey.isEmpty)
        XCTAssertFalse(ApiRequest.appsec.isEmpty)
        XCTAssertFalse(ApiRequest.appkey.contains("$("), "构建变量未展开时不能把字面量当 appkey")
        XCTAssertFalse(ApiRequest.appsec.contains("$("), "构建变量未展开时不能把字面量当 appsec")
        XCTAssertEqual(ApiRequest.appkey.count, 16, "B 站 appkey 固定 16 位")
        XCTAssertEqual(ApiRequest.appsec.count, 32, "B 站 appsec 固定 32 位")
    }

    /// 未配置环境下必须与公开常量一致（默认构建的行为不变）
    func testDefaultBuildUsesPublicConstants() {
        let raw = Bundle.main.object(forInfoDictionaryKey: "BilibiliAppKey") as? String
        let resolvedFromBundle = BilibiliCredential.resolve(value: raw,
                                                            fallback: BilibiliCredential.publicAppKey)
        XCTAssertEqual(ApiRequest.appkey, resolvedFromBundle)
        XCTAssertEqual(ApiRequest.appsec,
                       BilibiliCredential.resolve(value: Bundle.main.object(forInfoDictionaryKey: "BilibiliAppSecret") as? String,
                                                  fallback: BilibiliCredential.publicAppSecret))
    }
}
