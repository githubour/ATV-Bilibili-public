//
//  CookieManager.swift
//  ATV-Bilibili
//
//  Created by Etan Chen on 2021/3/28.
//

import Foundation

struct StoredCookie: Codable, Equatable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresDate: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool

    init(cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expiresDate = cookie.expiresDate
        isSecure = cookie.isSecure
        isHTTPOnly = cookie.isHTTPOnly
    }

    func makeHTTPCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .name: name,
            .path: path,
            .value: value,
        ]
        if let expiresDate {
            properties[.expires] = expiresDate
        }
        if isSecure {
            properties[.secure] = "TRUE"
        }
        properties[HTTPCookiePropertyKey("HttpOnly")] = isHTTPOnly ? "TRUE" : "FALSE"
        return HTTPCookie(properties: properties)
    }
}

/// 账号级 Cookie 存储：每个账号独立持有一套 Cookie，互不串扰。
/// tvOS 上 HTTPCookieStorage 没有可用的独立实例初始化入口（只有 shared / App Group），
/// 无法做到「每账号一套存储」，因此改为自管 `[HTTPCookie]`：切号只切换「当前活动账号」，
/// 其它账号的 Cookie 原样保留；请求头里的 Cookie 由活动账号在**请求创建时**快照注入
/// （见 WebRequest / ApiRequest），后续换号不会改写已在途请求，故不会串用新账号的 Cookie。
class CookieHandler {
    static let shared: CookieHandler = .init()

    private let lock = NSLock()
    /// 账号 mid → 该账号的 Cookie（独立持有）
    private var accountCookies: [Int: [HTTPCookie]] = [:]
    /// 无活动账号（未登录 / 登出）时的临时 Cookie
    private var guestCookies: [HTTPCookie] = []
    private var activeMID: Int?

    /// 当前活动账号的 Cookie 快照；无活动账号时用 guestCookies
    var activeCookies: [HTTPCookie] {
        lock.lock()
        defer { lock.unlock() }
        guard let activeMID else { return guestCookies }
        return accountCookies[activeMID] ?? []
    }

    /// 取某账号持有的 Cookie（用于检查 / 诊断）
    func cookies(forAccount mid: Int) -> [HTTPCookie] {
        lock.lock()
        defer { lock.unlock() }
        return accountCookies[mid] ?? []
    }

    /// 切换活动账号，并用该账号的 Cookie 覆盖其独立存储（mid 为 nil 表示登出 / 无账号）
    func activateAccount(mid: Int?, cookies: [StoredCookie]) {
        let httpCookies = cookies.compactMap { $0.makeHTTPCookie() }
        lock.lock()
        activeMID = mid
        if let mid {
            accountCookies[mid] = httpCookies
        } else {
            guestCookies = httpCookies
        }
        lock.unlock()
    }

    /// 命中指定 URL 的活动账号 Cookie（按 domain / path 匹配）
    func cookies(for url: URL) -> [HTTPCookie] {
        let host = url.host?.lowercased() ?? ""
        return activeCookies.filter { cookie in
            domainMatches(cookieDomain: cookie.domain, host: host) && pathMatches(cookiePath: cookie.path, urlPath: url.path)
        }
    }

    func getCookie(forURL url: String) -> [HTTPCookie] {
        guard let computedUrl = URL(string: url) else { return [] }
        return cookies(for: computedUrl)
    }

    /// 生成直接可用的 Cookie 请求头值；无匹配 Cookie 时返回 nil
    func cookieHeader(for url: URL) -> String? {
        let matched = cookies(for: url)
        guard !matched.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: matched)["Cookie"]
    }

    func cookieHeader(forURL url: String) -> String? {
        guard let computedUrl = URL(string: url) else { return nil }
        return cookieHeader(for: computedUrl)
    }

    /// 指定账号的 Cookie 头快照。请求层用它把 token 与 cookie 绑定到同一个 mid，
    /// 避免“构造请求时切号”导致 A 的 token 配 B 的 cookie。
    func cookieHeader(for url: URL, mid: Int?) -> String? {
        let list: [HTTPCookie]
        lock.lock()
        if let mid {
            list = accountCookies[mid] ?? []
        } else {
            list = guestCookies
        }
        lock.unlock()
        let host = url.host?.lowercased() ?? ""
        let matched = list.filter { cookie in
            domainMatches(cookieDomain: cookie.domain, host: host) && pathMatches(cookiePath: cookie.path, urlPath: url.path)
        }
        guard !matched.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: matched)["Cookie"]
    }

    /// 刷新 token 时按 mid 更新该账号的 cookie（不切换当前活动账号）。
    func updateAccountCookies(mid: Int, cookies: [HTTPCookie]) {
        lock.lock()
        accountCookies[mid] = cookies
        lock.unlock()
    }

    /// 删除账号时同步清掉它持有的 cookie，避免同一 mid 再次登录时复用旧会话。
    func removeAccountCookies(mid: Int) {
        lock.lock()
        accountCookies[mid] = nil
        lock.unlock()
    }

    func currentStoredCookies() -> [StoredCookie] {
        activeCookies.map(StoredCookie.init)
    }

    func backupCookies() {
        AccountManager.shared.syncActiveAccountCookies()
    }

    func removeCookie() {
        setActiveCookies([])
    }

    func saveCookie(list: [HTTPCookie], syncWithAccount: Bool = true) {
        setActiveCookies(list)
        if syncWithAccount {
            backupCookies()
        }
    }

    func csrf() -> String? {
        let cookies = getCookie(forURL: "https://bilibili.com")
        return cookies.first(where: { $0.name == "bili_jct" })?.value
    }

    // MARK: - Private

    private func setActiveCookies(_ cookies: [HTTPCookie]) {
        lock.lock()
        if let activeMID {
            accountCookies[activeMID] = cookies
        } else {
            guestCookies = cookies
        }
        lock.unlock()
    }

    private func domainMatches(cookieDomain: String, host: String) -> Bool {
        let domain = cookieDomain.lowercased()
        if domain.hasPrefix(".") {
            let bare = String(domain.dropFirst())
            return host == bare || host.hasSuffix(domain)
        }
        return host == domain || host.hasSuffix("." + domain)
    }

    private func pathMatches(cookiePath: String, urlPath: String) -> Bool {
        guard !cookiePath.isEmpty, cookiePath != "/" else { return true }
        return urlPath.hasPrefix(cookiePath)
    }
}
