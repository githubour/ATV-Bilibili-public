//
//  ApiRequest.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2021/4/25.
//

import Alamofire
import CryptoKit
import Foundation

struct LoginToken: Codable, Equatable {
    let mid: Int
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    var expireDate: Date?
}

enum ApiRequest {
    static let appkey = "5ae412b53418aac5"
    static let appsec = "5b9cf6c9786efd204dcf0c1ce2d08436"

    /// App 接口专用会话：关闭 URLSession 自身的 Cookie 存储，
    /// 统一由 CookieHandler 按请求快照注入，避免共享存储里的旧账号 cookie 混入。
    private static let session: Session = {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return Session(configuration: config)
    }()

    /// 同一 mid 的 refresh 只跑一次；并发请求同时收到 -101 时复用同一个 Task
    private struct RefreshEntry {
        let id: UUID
        let task: Task<Bool, Never>
    }

    private static let refreshLock = NSLock()
    private static var refreshEntries: [Int: RefreshEntry] = [:]

    private static func withRefreshLock<T>(_ body: () -> T) -> T {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        return body()
    }

    enum EndPoint {
        static let loginQR = "https://passport.bilibili.com/x/passport-tv-login/qrcode/auth_code"
        static let verifyQR = "https://passport.bilibili.com/x/passport-tv-login/qrcode/poll"
        static let refresh = "https://passport.bilibili.com/api/v2/oauth2/refresh_token"
        static let feed = "https://app.bilibili.com/x/v2/feed/index"
        // 推荐流不感兴趣反馈(PiliPlus/bili-webos 双源核实): reason_id 1=不感兴趣(当前视频) 4=不想看此UP主
        static let feedDislike = "https://app.bilibili.com/x/feed/dislike"
        static let season = "https://api.bilibili.com/pgc/view/v2/app/season"
        static let dislike = "https://app.biliapi.net/x/v2/view/dislike"
        static let upSpaceArchive = "https://app.bilibili.com/x/v2/space/archive/cursor"
    }

    enum LoginState {
        case success(token: LoginToken, cookies: [HTTPCookie])
        case fail
        case expire
        case waiting
    }

    static func getToken() -> LoginToken? {
        return AccountManager.shared.activeAccount?.token
    }

    static func isLogin() -> Bool {
        return AccountManager.shared.isLoggedIn
    }

    static func sign(for param: [String: Any]) -> [String: Any] {
        var newParam = param
        newParam["appkey"] = appkey
        newParam["ts"] = "\(Int(Date().timeIntervalSince1970))"
        newParam["local_id"] = "0"
        newParam["mobi_app"] = "iphone"
        newParam["device"] = "pad"
        newParam["device_name"] = "iPad"
        var rawParam = newParam
            .sorted(by: { $0.0 < $1.0 })
            .map({ "\($0.key)=\($0.value)" })
            .joined(separator: "&")
        rawParam.append(appsec)

        // 与 WBI 签名共用同一套 MD5 实现(WbiCrypto.md5Hex)
        let md5 = WbiCrypto.md5Hex(rawParam)
        newParam["sign"] = md5
        return newParam
    }

    /// 移除当前账号；返回值表示是否还有其他账号剩余
    @discardableResult
    static func logout() -> Bool {
        guard let account = AccountManager.shared.activeAccount else { return false }
        return AccountManager.shared.removeAccount(account)
    }

    /// 请求原始响应体，已做签名与状态码校验。
    /// - recoverAuth: -101 时先尝试一次 refresh 并重试；refresh 自身必须传 false，避免递归。
    /// - accountOverride: 刷新等后台任务固定使用发起时的账号，不随当前活动账号变化。
    static func requestData(_ url: URLConvertible,
                            method: HTTPMethod = .get,
                            parameters: Parameters = [:],
                            auth: Bool = true,
                            encoding: ParameterEncoding = URLEncoding.default,
                            recoverAuth: Bool = true,
                            accountOverride: AccountManager.Account? = nil) async throws -> Data
    {
        var didRecoverAuth = false
        while true {
            // 请求创建时一次性快照账号：token 与 Cookie 必须来自同一个 mid，
            // 否则构造期间切号会出现 A 的 access_key 配 B 的 cookie。
            let account = accountOverride ?? AccountManager.shared.activeAccount
            let requestMID = account?.profile.mid
            var parameters = parameters
            if auth {
                parameters["access_key"] = account?.token.accessToken
            }
            parameters = sign(for: parameters)
            var headers = HTTPHeaders()
            if let resolvedURL = try? url.asURL(),
               let cookieHeader = CookieHandler.shared.cookieHeader(for: resolvedURL, mid: requestMID)
            {
                headers.add(HTTPHeader(name: "Cookie", value: cookieHeader))
            }
            let data = try await session.request(url, method: method, parameters: parameters, encoding: encoding, headers: headers)
                .serializingData()
                .value
            guard let status = APIResponse.status(from: data), status.code != 0 else { return data }
            if status.code == -101 {
                let canRecover = recoverAuth
                    && !didRecoverAuth
                    && auth
                    && requestMID != nil
                    && AccountManager.shared.activeAccount?.profile.mid == requestMID
                if canRecover,
                   await refreshToken(),
                   AccountManager.shared.activeAccount?.profile.mid == requestMID
                {
                    didRecoverAuth = true
                    continue
                }
                let isActive = await MainActor.run {
                    AccountManager.shared.handleAuthenticationFailure(mid: requestMID)
                }
                if isActive {
                    await MainActor.run { AppDelegate.shared.showLoginForExpiredSession() }
                }
            }
            Logger.warn("[api] code:\(status.code) \(status.message) url:\(url)")
            throw RequestError.statusFail(code: status.code, message: status.message)
        }
    }

    /// 只关心请求是否成功，不解析响应体
    static func requestVoid(_ url: URLConvertible,
                            method: HTTPMethod = .get,
                            parameters: Parameters = [:],
                            auth: Bool = true,
                            encoding: ParameterEncoding = URLEncoding.default) async throws
    {
        _ = try await requestData(url, method: method, parameters: parameters, auth: auth, encoding: encoding)
    }

    static func request<T: Decodable>(_ url: URLConvertible,
                                      method: HTTPMethod = .get,
                                      parameters: Parameters = [:],
                                      auth: Bool = true,
                                      encoding: ParameterEncoding = URLEncoding.default,
                                      decoder: JSONDecoder = JSONDecoder(),
                                      recoverAuth: Bool = true,
                                      accountOverride: AccountManager.Account? = nil) async throws -> T
    {
        let raw = try await requestData(url,
                                        method: method,
                                        parameters: parameters,
                                        auth: auth,
                                        encoding: encoding,
                                        recoverAuth: recoverAuth,
                                        accountOverride: accountOverride)
        let object = try APIResponse.extractDataObject(from: raw, dataObj: "data")
        do {
            return try decoder.decode(T.self, from: object)
        } catch {
            Logger.warn("[api] decode fail: \(error) url:\(url)")
            throw RequestError.decodeFail(message: "\(error)")
        }
    }

    struct LoginQR: Codable {
        let authCode: String
        let url: String
    }

    static func requestLoginQR() async throws -> LoginQR {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try await request(EndPoint.loginQR, method: .post, auth: false, decoder: decoder)
    }

    struct LoginResp: Codable {
        struct CookieInfo: Codable {
            let domains: [String]
            let cookies: [Cookie]
            func toCookies() -> [HTTPCookie] {
                domains.map { domain in
                    cookies.compactMap { $0.toCookie(domain: domain) }
                }.reduce([], +)
            }
        }

        struct Cookie: Codable {
            let name: String
            let value: String
            let httpOnly: Int
            let expires: Int

            func toCookie(domain: String) -> HTTPCookie? {
                HTTPCookie(properties: [.domain: domain,
                                        .name: name,
                                        .value: value,
                                        .expires: Date(timeIntervalSince1970: TimeInterval(expires)),
                                        HTTPCookiePropertyKey("HttpOnly"): httpOnly,
                                        .path: ""])
            }
        }

        var tokenInfo: LoginToken
        let cookieInfo: CookieInfo
    }

    /// 轮询扫码结果。86038 = 二维码过期，86039 = 等待扫码
    static func verifyLoginQR(code: String) async -> LoginState {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            var res: LoginResp = try await request(EndPoint.verifyQR,
                                                   method: .post,
                                                   parameters: ["auth_code": code],
                                                   auth: false,
                                                   decoder: decoder)
            res.tokenInfo.expireDate = Date().addingTimeInterval(TimeInterval(res.tokenInfo.expiresIn))
            let cookies = res.cookieInfo.toCookies()
            CookieHandler.shared.saveCookie(list: cookies, syncWithAccount: false)
            return .success(token: res.tokenInfo, cookies: cookies)
        } catch let error as RequestError {
            if case let .statusFail(code, _) = error {
                switch code {
                case 86038: return .expire
                case 86039: return .waiting
                default: break
                }
            }
            Logger.warn("[api] verifyLoginQR fail: \(error)")
            return .fail
        } catch {
            Logger.warn("[api] verifyLoginQR fail: \(error)")
            return .fail
        }
    }

    /// 刷新当前活动账号的 token；同一 mid 并发调用共享一个 Task。
    /// 返回是否刷新成功，供 -101 的请求决定是否重试。
    @discardableResult
    static func refreshToken() async -> Bool {
        // 不再 AF.cancelAllRequests()：它会连带取消默认会话上所有在途业务请求（推荐流等），
        // 用户视角是「页面加载集体失败」；过期 token 的在途请求让它们自己走各自的结果路径。
        guard let account = AccountManager.shared.activeAccount else { return false }
        let mid = account.profile.mid
        let entry: RefreshEntry = withRefreshLock {
            if let existing = refreshEntries[mid] { return existing }
            let id = UUID()
            let task = Task { await performRefresh(account: account) }
            let newEntry = RefreshEntry(id: id, task: task)
            refreshEntries[mid] = newEntry
            return newEntry
        }
        let result = await entry.task.value
        withRefreshLock {
            if refreshEntries[mid]?.id == entry.id {
                refreshEntries[mid] = nil
            }
        }
        return result
    }

    private static func performRefresh(account: AccountManager.Account) async -> Bool {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            var res: LoginResp = try await request(EndPoint.refresh,
                                                   method: .post,
                                                   parameters: ["refresh_token": account.token.refreshToken],
                                                   decoder: decoder,
                                                   recoverAuth: false,
                                                   accountOverride: account)
            res.tokenInfo.expireDate = Date().addingTimeInterval(TimeInterval(res.tokenInfo.expiresIn))
            let cookies = res.cookieInfo.toCookies()
            // 按发起刷新的 mid 写回：刷新期间用户可能已切到另一个账号
            AccountManager.shared.updateStoredAccountToken(mid: account.profile.mid,
                                                           token: res.tokenInfo,
                                                           cookies: cookies)
            CookieHandler.shared.updateAccountCookies(mid: account.profile.mid, cookies: cookies)
            return true
        } catch {
            Logger.warn("[api] refreshToken fail: \(error)")
            return false
        }
    }

    struct FeedResp: Codable {
        let items: [Items]

        struct Items: DisplayData, Codable {
            let can_play: Int?
            let title: String
            let param: String
            let args: Args
            let avatar_info: Avatar
            let player_args: PlayerArgs?
            let idx: Int
            let cover: String
            let goto: String
            let top_rcmd_reason: String?
            let bottom_rcmd_reason: String?
            let desc: String?
            let cover_left_text_1: String?
            let cover_left_text_2: String?
            let cover_left_text_3: String?
            let cover_right_text: String?

            enum CodingKeys: String, CodingKey {
                case can_play, title, param, args, idx, cover, goto, top_rcmd_reason, bottom_rcmd_reason, desc, player_args
                case cover_left_text_1, cover_left_text_2, cover_left_text_3, cover_right_text
                case avatar_info = "avatar"
            }

            var ownerName: String {
                return args.up_name ?? ""
            }

            var pic: URL? {
                return URL(string: cover)
            }

            var date: String? {
                if let top_rcmd_reason {
                    return top_rcmd_reason
                }
                if let bottom_rcmd_reason {
                    return bottom_rcmd_reason
                }
                if let desc, desc.contains("·") {
                    return desc.components(separatedBy: "·").last?.trimmingCharacters(in: .whitespaces)
                }
                return nil
            }

            var avatar: URL? { URL(string: avatar_info.cover ?? "") }
            var overlay: DisplayOverlay? {
                var leftItems = [DisplayOverlay.DisplayOverlayItem]()
                var rightItems = [DisplayOverlay.DisplayOverlayItem]()
                if let text = cover_left_text_1 {
                    leftItems.append(DisplayOverlay.DisplayOverlayItem(icon: "play.rectangle", text: text))
                }
                if let text = cover_left_text_2 {
                    leftItems.append(DisplayOverlay.DisplayOverlayItem(icon: "list.bullet.rectangle", text: text))
                }
                if let text = cover_right_text ?? cover_left_text_3 {
                    rightItems.append(DisplayOverlay.DisplayOverlayItem(icon: nil, text: text))
                }
                return DisplayOverlay(leftItems: leftItems, rightItems: rightItems)
            }
        }

        struct Args: Codable, Hashable {
            let up_name: String?
        }

        struct Avatar: Codable, Hashable {
            let cover: String?
        }

        struct PlayerArgs: Codable, Hashable {
            @LossyInt var aid: Int?
            @LossyInt var cid: Int?
            @LossyInt var duration: Int?
            let type: String?
        }
    }

    static func getFeeds(lastIdx: Int = 0) async throws -> [FeedResp.Items] {
        let idx = "\(lastIdx)"
        let resp: FeedResp = try await request(EndPoint.feed, parameters: ["idx": idx, "flush": "0", "column": "4", "device": "pad", "pull": idx == "0" ? "1" : "0"])
        return resp.items.filter({ $0.goto == "av" })
    }

    static func requestDislike(aid: Int, dislike: Bool) async throws {
        try await requestVoid(EndPoint.dislike, method: .post, parameters: ["aid": aid, "dislike": dislike ? 0 : 1])
    }

    // MARK: - 推荐流「不感兴趣」反馈

    /// 推荐流不感兴趣原因
    enum FeedDislikeReason: Int {
        /// 不感兴趣: 当前视频
        case currentVideo = 1
        /// 不感兴趣: 此UP主
        case upOwner = 4
    }

    /// 上报推荐流「不感兴趣」, 服务端会减少同类推荐(卡片数据里 aid 即可, 不需要 up mid)
    static func requestFeedDislike(aid: Int, reason: FeedDislikeReason) async throws {
        try await requestVoid(EndPoint.feedDislike, parameters: ["goto": "av", "id": aid, "reason_id": reason.rawValue, "build": 1, "mobi_app": "android"])
    }

    struct BangumiInfo: Codable, Hashable {
        struct Stat: Codable, Hashable {
            let coins, danmakus, favorite, favorites: Int
            let likes, reply, share, views: Int
        }

        struct Rights: Codable, Hashable {
            let area_limit: Int
            let ban_area_show: Int
        }

        struct UserStatus: Codable, Hashable {
            let follow: Int
            let follow_status: Int
        }

        let title: String
        let cover: String
        let evaluate: String?
        let season_id: Int
        let season_title: String
        let user_status: UserStatus
        let stat: Stat
        let rights: Rights
    }

    static func requestBangumiInfo(epid: Int) async throws -> BangumiInfo {
        let info: BangumiInfo = try await request(EndPoint.season, parameters: ["ep_id": "\(epid)"])
        return info
    }

    static func requestBangumiInfo(seasonID: Int) async throws -> BangumiInfo {
        let info: BangumiInfo = try await request(EndPoint.season, parameters: ["season_id": "\(seasonID)"])
        return info
    }

    struct UpSpaceListData: Codable, Hashable, DisplayData, PlayableData {
        let title: String
        let author: String
        let param: String
        let cover: URL?
        let play: Int
        let danmaku: Int
        let duration: Int
        let ctime: Int

        // PlayableData
        var aid: Int { return Int(param) ?? 0 }
        var cid: Int { return 0 }

        // DisplayData
        var ownerName: String {
            return author
        }

        var pic: URL? { return cover }
        var date: String? { DateFormatter.stringFor(timestamp: ctime) }
        var overlay: DisplayOverlay? {
            .video(play: play, danmaku: danmaku, durationText: TimeInterval(duration).timeString())
        }
    }

    static func requestUpSpaceVideo(mid: Int, lastAid: Int?, pageSize: Int = 20, order: String = "pubdate") async throws -> [UpSpaceListData] {
        struct Resp: Codable {
            let item: [UpSpaceListData]
        }

        var param: Parameters = ["vmid": mid, "ps": pageSize, "actionKey": "appkey", "disable_rcmd": 0, "fnval": 976, "fnver": 0, "force_host": 0, "fourk": 1, "order": order, "player_net": 1, "qn": 120]
        if let lastAid {
            param["aid"] = lastAid
        }
        let resp: Resp = try await request(EndPoint.upSpaceArchive, parameters: param)
        return resp.item
    }
}
