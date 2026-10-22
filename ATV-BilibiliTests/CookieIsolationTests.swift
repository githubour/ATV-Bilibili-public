//
//  CookieIsolationTests.swift
//  ATV-BilibiliTests
//
//  E4 复现：多账号 Cookie 隔离。切号后新请求只带新账号的 Cookie；
// 请求头里的 Cookie 在请求创建时快照生成，故已在途请求仍用发起时账号的 Cookie。
//

@testable import ATV_Bilibili
import XCTest

final class CookieIsolationTests: XCTestCase {
    /// 用高位随机 mid 避免与宿主 App 里真实登录的账号冲突
    private let midA = 9_100_001
    private let midB = 9_100_002

    // MARK: - Helpers

    private func storedCsrf(_ value: String) -> StoredCookie? {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .domain: ".bilibili.com",
            .name: "bili_jct",
            .path: "/",
            .value: value,
        ]
        guard let cookie = HTTPCookie(properties: properties) else { return nil }
        return StoredCookie(cookie: cookie)
    }

    private func activate(mid: Int, csrf: String) {
        CookieHandler.shared.activateAccount(mid: mid, cookies: [storedCsrf(csrf)].compactMap { $0 })
    }

    private func header(for url: String) -> String? {
        CookieHandler.shared.cookieHeader(forURL: url)
    }

    override func tearDown() {
        // 复位活动账号，避免污染其它用例
        CookieHandler.shared.activateAccount(mid: nil, cookies: [])
        super.tearDown()
    }

    // MARK: - Tests

    /// 每个账号各自持有 Cookie，互不是同一份
    func testAccountCookiesAreIsolated() {
        activate(mid: midA, csrf: "csrfA")
        activate(mid: midB, csrf: "csrfB")
        let cookiesA = CookieHandler.shared.cookies(forAccount: midA)
        let cookiesB = CookieHandler.shared.cookies(forAccount: midB)
        XCTAssertEqual(cookiesA.first(where: { $0.name == "bili_jct" })?.value, "csrfA")
        XCTAssertEqual(cookiesB.first(where: { $0.name == "bili_jct" })?.value, "csrfB")
    }

    /// 切到新账号后，新请求只带新账号 Cookie，不复用旧账号；旧账号 Cookie 原样保留
    func testActivatingAccountDoesNotCarryPreviousCookie() {
        activate(mid: midA, csrf: "csrfA")
        XCTAssertEqual(CookieHandler.shared.csrf(), "csrfA")
        XCTAssertTrue(header(for: "https://bilibili.com")?.contains("csrfA") ?? false)

        activate(mid: midB, csrf: "csrfB")
        // 新活动账号的请求只带 B 的 Cookie，不再串用旧账号 A
        XCTAssertEqual(CookieHandler.shared.csrf(), "csrfB")
        let headerB = header(for: "https://bilibili.com")
        XCTAssertTrue(headerB?.contains("csrfB") ?? false)
        XCTAssertFalse(headerB?.contains("csrfA") ?? true)
        // A 的独立存储不因切号被清空
        XCTAssertEqual(CookieHandler.shared.cookies(forAccount: midA).first(where: { $0.name == "bili_jct" })?.value, "csrfA")
    }

    /// 请求层按显式 mid 取 Cookie：即使当前活动账号已切到 B，构造 A 的请求仍只带 A 的 Cookie
    func testExplicitMIDCookieHeaderDoesNotUseActiveAccount() {
        activate(mid: midA, csrf: "csrfA")
        activate(mid: midB, csrf: "csrfB")
        guard let url = URL(string: "https://bilibili.com") else { return XCTFail("bad url") }
        let headerA = CookieHandler.shared.cookieHeader(for: url, mid: midA)
        XCTAssertTrue(headerA?.contains("csrfA") ?? false)
        XCTAssertFalse(headerA?.contains("csrfB") ?? true)
    }

    /// 刷新时按 mid 更新 Cookie 不能切换活动账号，也不能污染另一个账号
    func testUpdateAccountCookiesByMIDDoesNotAffectActiveAccount() {
        activate(mid: midA, csrf: "csrfA")
        activate(mid: midB, csrf: "csrfB")
        guard let stored = storedCsrf("csrfA2"), let newA = stored.makeHTTPCookie() else {
            return XCTFail("bad cookie")
        }
        CookieHandler.shared.updateAccountCookies(mid: midA, cookies: [newA])
        XCTAssertEqual(CookieHandler.shared.cookies(forAccount: midA).first(where: { $0.name == "bili_jct" })?.value,
                       "csrfA2")
        XCTAssertEqual(CookieHandler.shared.cookies(forAccount: midB).first(where: { $0.name == "bili_jct" })?.value,
                       "csrfB")
        XCTAssertEqual(CookieHandler.shared.csrf(), "csrfB")
    }

    /// 在途请求：请求头的 Cookie 是创建时的快照，换号不改写已生成的请求
    func testInFlightCookieHeaderSnapshotStaysWithItsAccount() {
        activate(mid: midA, csrf: "csrfA")
        let inFlightHeader = header(for: "https://bilibili.com") // 请求创建时生成

        activate(mid: midB, csrf: "csrfB")
        // 已生成的请求头不随换号改写 —— 仍在途的请求继续用发起时账号的 Cookie
        XCTAssertTrue(inFlightHeader?.contains("csrfA") ?? false)
        XCTAssertFalse(inFlightHeader?.contains("csrfB") ?? true)
        // 之后的新请求用新账号
        XCTAssertEqual(CookieHandler.shared.csrf(), "csrfB")
    }
}
