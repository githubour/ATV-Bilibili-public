//
//  WebRequest+WbiSign.swift
//  ATV-Bilibili
//
//  Created by yicheng on 1/12/2024.
//

import Alamofire
import CryptoKit
import Foundation

extension WebRequest {
    /// WBI 预热请求专用：不读写 URLSession 的共享 cookie 存储，
    /// Cookie 一律从 CookieHandler 按当前账号显式注入。
    private static let wbiURLSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    private static let wbiAFSession: Session = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return Session(configuration: config)
    }()

    static func addWbiSign(method: HTTPMethod = .get,
                           url: URLConvertible,
                           parameters: Parameters = [:],
                           onComplete: @escaping (String?) -> Void)
    {
        do {
            let urlObj = try url.asURL()
            if method == .get {
                var request = URLRequest(url: urlObj)
                request.method = .get
                request = try URLEncoding.queryString.encode(request, with: parameters)
                if let query = request.url?.query(percentEncoded: true) {
                    biliWbiSign(param: query) { res in
                        if let res {
                            let urlString = urlObj.absoluteString + "?" + res
                            onComplete(urlString)
                            return
                        } else {
                            onComplete(nil)
                        }
                    }
                    return
                }
            }
            onComplete(nil)
        } catch {
            onComplete(nil)
        }
    }

    // https://github.com/SocialSisterYi/bilibili-API-collect/blob/master/docs/misc/sign/wbi.md#Swift
    private static func biliWbiSign(param: String, completion: @escaping (String?) -> Void) {
        func getWebId(needRefresh: Bool = false, completion: @escaping (String?) -> Void) {
            if let cached = WebIdCache.shared.webId, !needRefresh {
                completion(cached)
                return
            }

            // Generate random visit_id (16 char lowercase hex string)
            let visitId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
            let urlString = "https://live.bilibili.com/p/eden/area-tags?parentAreaId=2&areaId=0&visit_id=\(visitId)"

            guard let url = URL(string: urlString) else {
                completion(nil)
                return
            }

            var request = URLRequest(url: url)
            request.setValue(Keys.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(Keys.liveReferer, forHTTPHeaderField: "Referer")

            if let cookieHeader = CookieHandler.shared.cookieHeader(for: url) {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }

            let task = wbiURLSession.dataTask(with: request) { data, response, error in
                guard let data = data,
                      let html = String(data: data, encoding: .utf8),
                      error == nil
                else {
                    completion(nil)
                    return
                }

                do {
                    // Look for window._render_data_ = {"access_id":"..."}
                    let regex = try NSRegularExpression(pattern: #"window\._render_data_\s*=\s*\{\"access_id\":\"([^\"]+)\""#, options: [])
                    if let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                       let range = Range(match.range(at: 1), in: html)
                    {
                        let accessId = String(html[range])
                        WebIdCache.shared.store(accessId)
                        completion(accessId)
                        return
                    }
                } catch {}

                completion(nil)
            }
            task.resume()
        }

        func getWbiKeys(completion: @escaping (Result<(imgKey: String, subKey: String, refresh: Bool), Error>) -> Void) {
            if let cached = WbiKeysCache.shared.cachedKeys(maxAge: 60 * 60 * 2) {
                completion(.success((cached.imgKey, cached.subKey, false)))
                return
            }

            var headers: HTTPHeaders = [
                "User-Agent": Keys.userAgent,
                "Referer": Keys.referer,
            ]
            if let cookieHeader = CookieHandler.shared.cookieHeader(forURL: WebRequest.EndPoint.nav) {
                headers.add(HTTPHeader(name: "Cookie", value: cookieHeader))
            }

            wbiAFSession.request(WebRequest.EndPoint.nav, headers: headers).responseData { response in
                switch response.result {
                case let .success(value):
                    let imgURL = APIResponse.string(from: value, path: "data", "wbi_img", "img_url")
                    let subURL = APIResponse.string(from: value, path: "data", "wbi_img", "sub_url")
                    let imgKey = imgURL.components(separatedBy: "/").last?.components(separatedBy: ".").first ?? ""
                    let subKey = subURL.components(separatedBy: "/").last?.components(separatedBy: ".").first ?? ""
                    // nav 响应结构变化/风控页会解析出空串：绝不能当 success 往下走，
                    // deriveMixinKey 对短串取下标会直接越界崩溃——签名失败降级即可
                    guard !imgKey.isEmpty, !subKey.isEmpty else {
                        completion(.failure(WbiSignError.emptyKeys))
                        return
                    }
                    WbiKeysCache.shared.update(imgKey: imgKey, subKey: subKey)
                    completion(.success((imgKey, subKey, true)))
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        }

        getWbiKeys { result in
            switch result {
            case let .success(keys):
                getWebId(needRefresh: keys.refresh) { webId in
                    let spdParam = param.components(separatedBy: "&")
                    var spdDicParam = [String: String]()
                    for pair in spdParam {
                        // 只按第一个 = 切分：值里允许出现 =（例如 base64 / 用户输入）
                        let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        if components.count == 2 {
                            // URL decode the parameter value
                            let decodedValue = String(components[1]).removingPercentEncoding ?? String(components[1])
                            spdDicParam[String(components[0])] = decodedValue
                        }
                    }

                    // Add w_webid parameter
                    if let webId = webId {
                        spdDicParam["w_webid"] = webId
                    }

                    let signedParams = WbiCrypto.encWbi(params: spdDicParam, imgKey: keys.imgKey, subKey: keys.subKey)

                    // Correct parameter ordering (reference: bilibili-plus)
                    let wbiKeys = ["w_webid", "w_rid", "wts"]
                    var orderedParams = signedParams
                        .filter { !wbiKeys.contains($0.key) }
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }

                    // Append WBI parameters in fixed order
                    for key in wbiKeys {
                        if let value = signedParams[key] {
                            orderedParams.append("\(key)=\(value)")
                        }
                    }

                    // 签名串用原始值（与既有算法一致）；发出去的 query 必须把值里的
                    // & + = # 编码掉，否则会被服务端当成新的参数边界，导致签名错位。
                    let query = orderedParams.map { pair -> String in
                        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        guard parts.count == 2 else { return pair }
                        return "\(parts[0])=\(WbiCrypto.escapeQueryValue(String(parts[1])))"
                    }.joined(separator: "&")
                    completion(query)
                }
            case let .failure(error):
                Logger.warn("[wbi] get keys fail: \(error)")
                completion(nil)
            }
        }
    }

    // MARK: - WbiKeys Cache

    /// wbi keys 缓存：Alamofire 回调线程写、任意请求线程读（-352 时还会被清），
    /// 全部字段用一把锁保护；锁内只有纯赋值/取值
    final class WbiKeysCache {
        static let shared = WbiKeysCache()

        private let lock = NSLock()
        private var _imgKey: String?
        private var _subKey: String?
        private var _lastUpdate: Date?

        /// 未过期（maxAge 内且同一天）则返回缓存键对，否则 nil
        func cachedKeys(maxAge: TimeInterval) -> (imgKey: String, subKey: String)? {
            lock.lock(); defer { lock.unlock() }
            guard let imgKey = _imgKey, let subKey = _subKey, let lastUpdate = _lastUpdate,
                  Date().timeIntervalSince(lastUpdate) < maxAge,
                  Calendar.current.isDate(Date(), inSameDayAs: lastUpdate)
            else { return nil }
            return (imgKey, subKey)
        }

        func update(imgKey: String, subKey: String) {
            lock.lock(); defer { lock.unlock() }
            _imgKey = imgKey
            _subKey = subKey
            _lastUpdate = Date()
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            _imgKey = nil
            _subKey = nil
            _lastUpdate = nil
        }

        private init() {}
    }

    /// WBI 签名环节的可预期失败
    private struct WbiSignError: LocalizedError {
        static let emptyKeys = WbiSignError()
        var errorDescription: String? { "wbi keys 解析为空（nav 接口异常或被风控页拦截）" }
    }
}

/// webId 缓存：URLSession 回调线程写、任意请求线程读，锁保护。
/// （曾以「函数体内嵌套 class」的形式藏在 biliWbiSign 里，提取到文件作用域）
private final class WebIdCache {
    static let shared = WebIdCache()

    private let lock = NSLock()
    private var _webId: String?

    var webId: String? {
        lock.lock(); defer { lock.unlock() }
        return _webId
    }

    func store(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        _webId = value
    }

    private init() {}
}

/// WBI 签名纯函数：mixin key 派生 / 参数签名 / MD5。
/// 供 biliWbiSign 与单元测试共同使用（encWbi 额外读取当前时间作为 wts）。
enum WbiCrypto {
    static func deriveMixinKey(_ orig: String) -> String {
        // 防御：imgKey/subKey 异常为空/短串时按表取下标会越界崩溃；
        // 返回空串只会让本次签名错误（服务端拒绝→清缓存重取），属安全降级
        guard orig.count >= 64 else { return "" }
        let mixinKeyEncTab = [
            46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
            33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
            61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
            36, 20, 34, 44, 52,
        ]
        return String(mixinKeyEncTab.map { orig[orig.index(orig.startIndex, offsetBy: $0)] }.prefix(32))
    }

    static func encWbi(params: [String: Any], imgKey: String, subKey: String) -> [String: Any] {
        var params = params
        let mixinKey = deriveMixinKey(imgKey + subKey)
        let currTime = Int(Date().timeIntervalSince1970)
        params["wts"] = currTime

        // Keep parameters as sorted array for query generation
        let sortedParams = params.sorted { $0.key < $1.key }

        // Generate query string directly from sorted array
        let query = sortedParams
            .map { key, value in
                let filteredValue = String(describing: value).filter { !"!'()*".contains($0) }
                return "\(key)=\(filteredValue)"
            }
            .joined(separator: "&")

        let wbiSign = md5Hex(query + mixinKey)
        params["w_rid"] = wbiSign
        return params
    }

    /// 只编码会破坏 query 结构的字符；中文/空格保持现状，避免改变既有签名行为。
    static func escapeQueryValue(_ value: String) -> String {
        var result = value
        for (raw, encoded) in [("&", "%26"), ("+", "%2B"), ("=", "%3D"), ("#", "%23")] {
            result = result.replacingOccurrences(of: raw, with: encoded)
        }
        return result
    }

    static func md5Hex(_ string: String) -> String {
        let messageData = string.data(using: .utf8) ?? Data()
        let digestData = Insecure.MD5.hash(data: messageData)
        let digestHex = String(digestData.map { String(format: "%02hhx", $0) }.joined().prefix(32))
        return digestHex
    }
}
