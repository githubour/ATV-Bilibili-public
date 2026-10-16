//
//  WebRequest.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2021/4/29.
//

import Alamofire
import Foundation
import SwiftProtobuf

enum RequestError: Error {
    case networkFail
    case statusFail(code: Int, message: String)
    case decodeFail(message: String)
}

enum ValidationError: Error {
    case argumentInvalid(message: String)
}

struct PlayURLRequestOptions: Hashable {
    let qn: Int
    let fnval: Int
    let enableFourK: Bool
    let supportMultiAudio: Bool

    static let regular = PlayURLRequestOptions(qn: 127,
                                               fnval: 976,
                                               enableFourK: true,
                                               supportMultiAudio: true)
    static let featuredPreview = PlayURLRequestOptions(qn: 64,
                                                       fnval: 16,
                                                       enableFourK: false,
                                                       supportMultiAudio: false)
}

enum NoCookieSession {
    static let session: Session = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return Session(configuration: config)
    }()
}

enum BLSession {
    static let `default`: Session = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return Session(configuration: config)
    }()
}

enum WebRequest {
    enum EndPoint {
        static let logout = "https://passport.bilibili.com/login/exit/v2"
        static let info = "https://api.bilibili.com/x/web-interface/view"
        static let fav = "https://api.bilibili.com/x/v3/fav/resource/list"
        static let favList = "https://api.bilibili.com/x/v3/fav/folder/created/list-all"
        static let favFolderCollectedList = "https://api.bilibili.com/x/v3/fav/folder/collected/list"
        static let favSeason = "https://api.bilibili.com/x/space/fav/season/list"
        static let heartbeat = "https://api.bilibili.com/x/click-interface/web/heartbeat"
        static let history = "https://api.bilibili.com/x/v2/history"
        static let webBangumiSeason = "https://api.bilibili.com/pgc/view/web/season"
        static let like = "https://api.bilibili.com/x/web-interface/archive/like"
        static let likeStatus = "https://api.bilibili.com/x/web-interface/archive/has/like"
        static let coin = "https://api.bilibili.com/x/web-interface/coin/add"
        static let playerInfo = "https://api.bilibili.com/x/player/wbi/v2"
        static let playUrl = "https://api.bilibili.com/x/player/wbi/playurl"
        static let pcgPlayUrl = "https://api.bilibili.com/pgc/player/web/playurl"
        static let bangumiSeason = "https://bangumi.bilibili.com/view/web_api/season"
        static let userEpisodeInfo = "https://api.bilibili.com/pgc/season/episode/web/info"
        static let danmakuWebView = "https://api.bilibili.com/x/v2/dm/web/view"
        static let danmakuList = "https://api.bilibili.com/x/v2/dm/list/seg.so"

        static let homePage = "https://www.bilibili.com"
        static let viewDetail = "https://api.bilibili.com/x/web-interface/view/detail"
        static let coins = "https://api.bilibili.com/x/web-interface/archive/coins"
        static let accountExp = "https://www.bilibili.com/plus/account/exp.php"
        static let favResourceDeal = "https://api.bilibili.com/x/v3/fav/resource/deal"
        static let favFavoured = "https://api.bilibili.com/x/v2/fav/video/favoured"
        static let reply = "https://api.bilibili.com/x/v2/reply"
        static let playerPagelist = "https://api.bilibili.com/x/player/pagelist"
        static let relationModify = "https://api.bilibili.com/x/relation/modify"
        static let spaceAccInfo = "https://api.bilibili.com/x/space/wbi/acc/info"
        static let spaceAccRelation = "https://api.bilibili.com/x/space/wbi/acc/relation"
        static let nav = "https://api.bilibili.com/x/web-interface/nav"

        // —— 以下收归自各功能页散落的 WebRequest.EndPoint extension ——
        // 稍后再看(ToView)
        static let toViewList = "https://api.bilibili.com/x/v2/history/toview"
        static let toViewDel = "https://api.bilibili.com/x/v2/history/toview/del"
        static let toViewAdd = "https://api.bilibili.com/x/v2/history/toview/add"
        // 关注 UP(FollowUps) / 动态流(FollowsGrid)
        static let followings = "https://api.bilibili.com/x/relation/followings"
        static let dynamicFeed = "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all"
        // 搜索(Search)
        static let searchAll = "https://api.bilibili.com/x/web-interface/search/all/v2"
        static let searchSuggest = "https://api.bilibili.com/x/web-interface/suggest"
        static let searchTrending = "https://app.bilibili.com/x/v2/search/trending/ranking"
        // 追番(FollowBangumi) / 每周观看(WeeklyWatch) / 排行榜(Ranking)
        static let followBangumiList = "https://api.bilibili.com/x/space/bangumi/follow/list"
        static let popularSeriesList = "https://api.bilibili.com/x/web-interface/popular/series/list"
        static let popularSeriesOne = "https://api.bilibili.com/x/web-interface/popular/series/one"
        static let rank = "https://api.bilibili.com/x/web-interface/ranking/v2"
        static let seasonRank = "https://api.bilibili.com/pgc/web/rank/list"
        // 弹幕屏蔽词(VideoDanmakuFilter) / AI 总结(AISummaryPlugin)
        static let danmakuFilter = "https://api.bilibili.com/x/dm/filter/user"
        static let aiConclusion = "https://api.bilibili.com/x/web-interface/view/conclusion/get"
    }

    static func requestData(method: HTTPMethod = .get,
                            url: URLConvertible,
                            parameters: Parameters = [:],
                            headers: [String: String]? = nil,
                            noCookie: Bool = false,
                            complete: ((Result<Data, RequestError>) -> Void)? = nil)
    {
        var parameters = parameters
        if method != .get {
            parameters["biliCSRF"] = CookieHandler.shared.csrf()
            parameters["csrf"] = CookieHandler.shared.csrf()
        }

        var afheaders = HTTPHeaders()
        if let headers {
            for (k, v) in headers {
                afheaders.add(HTTPHeader(name: k, value: v))
            }
        }

        if !afheaders.contains(where: { $0.name == "User-Agent" }) {
            afheaders.add(.userAgent(Keys.userAgent))
        }

        if !afheaders.contains(where: { $0.name == "Referer" }) {
            afheaders.add(HTTPHeader(name: "Referer", value: Keys.referer))
        }

        // Session 配置(超时/无Cookie)在创建时已固定, 不在请求期修改
        let session = noCookie ? NoCookieSession.session : BLSession.default

        let completionHandler: (AFDataResponse<Data>) -> Void = { response in
            switch response.result {
            case let .success(data):
                complete?(.success(data))
            case let .failure(err):
                Logger.warn("[web] network fail: \(err)")
                complete?(.failure(.networkFail))
            }
        }

        addWbiSign(method: method, url: url, parameters: parameters) { wbiSign in
            if let wbiSign {
                session.request(wbiSign,
                                method: method,
                                encoding: URLEncoding.default,
                                headers: afheaders)
                    .responseData(completionHandler: completionHandler)
            } else {
                session.request(url,
                                method: method,
                                parameters: parameters,
                                encoding: URLEncoding.default,
                                headers: afheaders)
                    .responseData(completionHandler: completionHandler)
            }
        }
    }

    static func requestIndex() {
        requestData(url: EndPoint.homePage, complete: {
            _ in
            CookieHandler.shared.backupCookies()
        })
    }

    static func requestPB<T: SwiftProtobuf.Message>(method: HTTPMethod = .get,
                                                    url: URLConvertible,
                                                    parameters: Parameters = [:],
                                                    headers: [String: String]? = nil,
                                                    noCookie: Bool = false,
                                                    complete: ((Result<T, RequestError>) -> Void)? = nil)
    {
        requestData(method: method, url: url, parameters: parameters, headers: headers, noCookie: noCookie) { response in
            switch response {
            case let .success(data):
                do {
                    let protobufObject = try T(serializedBytes: data)
                    complete?(.success(protobufObject))
                } catch let err {
                    Logger.warn("Protobuf parsing error: \(err.localizedDescription)")
                    complete?(.failure(.decodeFail(message: "probobuf decode error: \(err)")))
                }
            case let .failure(err):
                complete?(.failure(err))
            }
        }
    }

    static func requestData(method: HTTPMethod = .get,
                            url: URLConvertible,
                            parameters: Parameters = [:],
                            headers: [String: String]? = nil,
                            noCookie: Bool = false) async throws -> Data
    {
        try await withCheckedThrowingContinuation { configure in
            requestData(method: method, url: url, parameters: parameters, headers: headers, noCookie: noCookie) { resp in
                configure.resume(with: resp)
            }
        }
    }

    /// 请求并把 dataObj 对应的子数据解码为 T
    static func request<T: Decodable>(method: HTTPMethod = .get,
                                      url: URLConvertible,
                                      parameters: Parameters = [:],
                                      headers: [String: String]? = nil,
                                      decoder: JSONDecoder? = nil,
                                      noCookie: Bool = false,
                                      dataObj: String = "data") async throws -> T
    {
        let raw = try await requestData(method: method, url: url, parameters: parameters, headers: headers, noCookie: noCookie)
        try throwIfStatusFail(raw, url: url)
        #if DEBUG
            Logger.debug("\(url) response: \(String(data: raw, encoding: .utf8) ?? "")")
        #endif
        let object = try APIResponse.extractDataObject(from: raw, dataObj: dataObj)
        do {
            return try (decoder ?? JSONDecoder()).decode(T.self, from: object)
        } catch {
            Logger.warn("[web] decode fail: \(error) url:\(url)")
            throw RequestError.decodeFail(message: "\(error)")
        }
    }

    /// 只关心请求是否成功，不解析响应体
    static func requestVoid(method: HTTPMethod = .get,
                            url: URLConvertible,
                            parameters: Parameters = [:],
                            headers: [String: String]? = nil,
                            noCookie: Bool = false) async throws
    {
        let raw = try await requestData(method: method, url: url, parameters: parameters, headers: headers, noCookie: noCookie)
        try throwIfStatusFail(raw, url: url)
    }

    private static func throwIfStatusFail(_ raw: Data, url: URLConvertible) throws {
        guard let status = APIResponse.status(from: raw), status.code != 0 else { return }
        Logger.warn("[web] code:\(status.code) \(status.message) url:\(url)")
        // 风控校验失败，清掉 wbi 签名缓存下次重新取
        if status.code == -352 {
            Logger.warn("WbiSign error (code=-352), clearing cache. URL: \(url)")
            WbiKeysCache.shared.clear()
        }
        throw RequestError.statusFail(code: status.code, message: status.message)
    }

    static func requestPB<T: SwiftProtobuf.Message>(method: HTTPMethod = .get,
                                                    url: URLConvertible,
                                                    parameters: Parameters = [:],
                                                    headers: [String: String]? = nil,
                                                    noCookie: Bool = false) async throws -> T
    {
        return try await withCheckedThrowingContinuation { configure in
            requestPB(method: method, url: url, parameters: parameters, headers: headers, noCookie: noCookie) {
                (res: Result<T, RequestError>) in
                switch res {
                case let .success(content):
                    configure.resume(returning: content)
                case let .failure(err):
                    configure.resume(throwing: err)
                }
            }
        }
    }
}

// MARK: - Video

/// 收藏夹列表接口的响应包装（requestFavVideosList / requestFavFolderCollectedList 共用）
private struct FavListResp: Codable {
    let list: [FavListData]
}

/// 收藏内容接口的响应包装（requestFavVideos / requestFavSeason 共用）
private struct FavMediasResp: Codable {
    let medias: [FavData]?
}

extension WebRequest {
    static func requestBangumiInfo(epid: Int) async throws -> BangumiInfo {
        let info: BangumiInfo = try await request(url: EndPoint.webBangumiSeason, parameters: ["ep_id": epid], dataObj: "result")
        return info
    }

    static func requestBangumiInfo(seasonID: Int) async throws -> BangumiInfo {
        let res: BangumiInfo = try await request(url: EndPoint.webBangumiSeason, parameters: ["season_id": seasonID], dataObj: "result")
        return res
    }

    static func requestBangumiSeasonView(epid: Int) async throws -> BangumiSeasonView {
        let info: BangumiSeasonView = try await request(url: EndPoint.bangumiSeason, parameters: ["ep_id": epid], dataObj: "result")
        return info
    }

    static func requestBangumiSeasonView(seasonID: Int) async throws -> BangumiSeasonView {
        let info: BangumiSeasonView = try await request(url: EndPoint.bangumiSeason, parameters: ["season_id": seasonID], dataObj: "result")
        return info
    }

    static func requestUserEpisodeInfo(epid: Int) async throws -> UserEpisodeInfo {
        try await request(url: EndPoint.userEpisodeInfo, parameters: ["ep_id": epid])
    }

    static func requestHistory() async throws -> [HistoryData] {
        try await request(url: EndPoint.history)
    }

    static func requestPlayerInfo(aid: Int, cid: Int) async throws -> PlayerInfo {
        try await request(url: EndPoint.playerInfo, parameters: ["aid": aid, "cid": cid])
    }

    static func requestDetailVideo(aid: Int) async throws -> VideoDetail {
        try await request(url: EndPoint.viewDetail, parameters: ["aid": aid])
    }

    static func requestFavVideosList() async throws -> [FavListData] {
        guard let mid = ApiRequest.getToken()?.mid else { return [] }
        let res: FavListResp = try await request(method: .get, url: EndPoint.favList, parameters: ["up_mid": mid])
        return res.list.map {
            $0.createBySelf = true
            return $0
        }
    }

    static func requestFavVideos(mid: String, page: Int) async throws -> [FavData] {
        let res: FavMediasResp = try await request(method: .get, url: EndPoint.fav, parameters: ["media_id": mid, "ps": "20", "pn": page, "platform": "web"])
        return res.medias ?? []
    }

    static func requestFavFolderCollectedList() async throws -> [FavListData] {
        guard let mid = ApiRequest.getToken()?.mid else { return [] }
        let res: FavListResp = try await request(method: .get, url: EndPoint.favFolderCollectedList, parameters: ["up_mid": mid, "pn": 1, "ps": 100, "platform": "web"])
        return res.list
    }

    static func requestFavSeason(seasonId: String, page: Int) async throws -> [FavData] {
        let res: FavMediasResp = try await request(method: .get, url: EndPoint.favSeason, parameters: ["season_id": seasonId, "ps": "20", "pn": page, "platform": "web"])
        return res.medias ?? []
    }

    static func reportWatchHistory(aid: Int, cid: Int, currentTime: Int, epid: Int? = nil, seasonId: Int? = nil, subType: Int? = nil) {
        var parameters: [String: Any] = [
            "aid": aid,
            "cid": cid,
            "played_time": currentTime,
        ]

        if epid ?? 0 > 0 || seasonId ?? 0 > 0 {
            // 番剧类型标识
            parameters["type"] = 4
            parameters["sub_type"] = subType ?? 1

            // 番剧ID
            if let epid = epid {
                parameters["epid"] = epid
            }
            if let seasonId = seasonId {
                parameters["sid"] = seasonId
            }

            // Web平台标识（关键：用于正确识别番剧历史记录）
            parameters["mobi_app"] = "web"
            parameters["device"] = "web"
            parameters["platform"] = "web"
        } else {
            parameters["type"] = 3
            parameters["sub_type"] = 0
        }

        Task {
            try? await requestVoid(method: .post, url: EndPoint.heartbeat, parameters: parameters)
        }
    }

    static func requestLike(aid: Int, like: Bool) async -> Bool {
        do {
            try await requestVoid(method: .post, url: EndPoint.like, parameters: ["aid": aid, "like": like ? "1" : "2"])
            return true
        } catch {
            return false
        }
    }

    /// 该接口 data 直接是 0/1
    static func requestLikeStatus(aid: Int) async -> Bool {
        let liked: Int? = try? await request(url: EndPoint.likeStatus, parameters: ["aid": aid])
        return liked == 1
    }

    static func requestCoin(aid: Int, num: Int) {
        Task {
            try? await requestVoid(method: .post, url: EndPoint.coin, parameters: ["aid": aid, "multiply": num, "select_like": 1])
        }
    }

    static func requestCoinStatus(aid: Int) async -> Int {
        struct Resp: Decodable {
            let multiply: Int
        }
        let resp: Resp? = try? await request(url: EndPoint.coins, parameters: ["aid": aid])
        return resp?.multiply ?? 0
    }

    /// 一键三连：点赞 + 投币 1 枚 + 收藏到第一个自建收藏夹。
    /// 点赞/收藏是开关语义接口，先查状态避免对已三连视频重复上报；
    /// 投币查今日已投倍数，投过就跳过。返回用户可读的结果描述
    static func requestOneClickTriple(aid: Int) async -> String {
        guard aid > 0 else { return "视频信息缺失，无法三连" }
        async let liked = requestLikeStatus(aid: aid)
        async let coinMulti = requestCoinStatus(aid: aid)
        async let favoured = requestFavoriteStatus(aid: aid)
        let (isLiked, multiply, isFavoured) = await(liked, coinMulti, favoured)

        var done = [String]()
        if !isLiked, await requestLike(aid: aid, like: true) {
            done.append("点赞")
        }
        if multiply == 0 {
            requestCoin(aid: aid, num: 1)
            done.append("投币")
        }
        if !isFavoured, let folder = try? await requestFavVideosList().first {
            requestFavorite(aid: aid, mid: folder.id)
            done.append("收藏至「\(folder.title)」")
        }

        if done.isEmpty {
            return "已经三连过啦"
        }
        return "已\(done.joined(separator: "、"))"
    }

    /// 该接口没有外层 code/data 包装
    static func requestTodayCoins() async -> Int {
        struct Resp: Decodable {
            let number: Int
        }
        let resp: Resp? = try? await request(url: EndPoint.accountExp, dataObj: "")
        return resp?.number ?? 0
    }

    static func requestFavorite(aid: Int, mid: Int) {
        Task {
            try? await requestVoid(method: .post, url: EndPoint.favResourceDeal, parameters: ["rid": aid, "type": 2, "add_media_ids": mid])
        }
    }

    static func removeFavorite(aid: Int, mid: [Int]) {
        Task {
            try? await requestVoid(method: .post, url: EndPoint.favResourceDeal, parameters: ["rid": aid, "type": 2, "del_media_ids": mid.map { "\($0)" }.joined(separator: ",")])
        }
    }

    static func requestFavoriteStatus(aid: Int) async -> Bool {
        struct Resp: Decodable {
            let favoured: Bool
        }
        let resp: Resp? = try? await request(url: EndPoint.favFavoured, parameters: ["aid": aid])
        return resp?.favoured ?? false
    }

    static func requestPlayUrl(aid: Int, cid: Int, options: PlayURLRequestOptions = .regular) async throws -> VideoPlayURLInfo {
        var parameters: [String: Any] = ["avid": aid,
                                         "cid": cid,
                                         "qn": options.qn,
                                         "type": "",
                                         "fnver": 0,
                                         "fnval": options.fnval,
                                         "otype": "json"]
        // 与 PGC 路径（requestPcgPlayUrl）对齐：4K 需要 fourk=1，
        // 多音轨（杜比全景声等）需要 support_multi_audio。此前该路径两个都没带。
        if options.supportMultiAudio {
            parameters["support_multi_audio"] = true
        }
        if options.enableFourK {
            parameters["fourk"] = 1
        }
        return try await request(url: EndPoint.playUrl, parameters: parameters)
    }

    static func requestPcgPlayUrl(aid: Int, cid: Int, options: PlayURLRequestOptions = .regular) async throws -> VideoPlayURLInfo {
        var parameters: [String: Any] = ["avid": aid,
                                         "cid": cid,
                                         "qn": options.qn,
                                         "fnver": 0,
                                         "fnval": options.fnval]
        if options.supportMultiAudio {
            parameters["support_multi_audio"] = true
        }
        if options.enableFourK {
            parameters["fourk"] = 1
        }
        return try await request(url: EndPoint.pcgPlayUrl,
                                 parameters: parameters,
                                 dataObj: "result")
    }

    static func requestAreaLimitPcgPlayUrl(epid: Int,
                                           cid: Int,
                                           area: String,
                                           options: PlayURLRequestOptions = .regular) async throws -> VideoPlayURLInfo
    {
        let customServer = Settings.areaLimitCustomServer
        guard !customServer.isEmpty else { throw ValidationError.argumentInvalid(message: "未设置解析服务器") }

        // 解析服务器必须使用ep_id参数，不能使用avid参数，解析服务器一般有缓存，area和ep_id必须保持一致，要不然会被缓存拦截
        let url = EndPoint.pcgPlayUrl.replacingOccurrences(of: "api.bilibili.com", with: customServer)
        var parameters: [String: Any] = ["ep_id": epid,
                                         "cid": cid,
                                         "qn": options.qn,
                                         "fnver": 0,
                                         "fnval": options.fnval,
                                         "area": area]
        if options.supportMultiAudio {
            parameters["support_multi_audio"] = 1
        }
        if options.enableFourK {
            parameters["fourk"] = 1
        }
        if let access_key = ApiRequest.getToken()?.accessToken {
            parameters["access_key"] = access_key
        }
        parameters["appkey"] = ApiRequest.appkey
        parameters["local_id"] = 0
        parameters["mobi_app"] = "android"

        return try await request(url: url,
                                 parameters: parameters,
                                 dataObj: "result")
    }

    static func requestReplys(aid: Int) async throws -> Replys {
        try await request(url: EndPoint.reply, parameters: ["type": 1, "oid": aid, "sort": 1, "nohot": 0])
    }

    static func requestSubtitle(url: URL) async throws -> [SubtitleContent] {
        struct SubtitleContentResp: Codable {
            let body: [SubtitleContent]
        }
        let resp = try await AF.request(url).serializingDecodable(SubtitleContentResp.self).value
        return resp.body
    }

    static func requestCid(aid: Int) async throws -> Int {
        struct Page: Decodable {
            let cid: Int
        }
        let pages: [Page] = try await request(url: EndPoint.playerPagelist, parameters: ["aid": aid, "jsonp": "jsonp"])
        guard let cid = pages.first?.cid else {
            throw RequestError.decodeFail(message: "pagelist 为空 aid:\(aid)")
        }
        return cid
    }

    static func requestDanmakuWebView(cid: Int) async throws -> DmWebViewReply {
        try await requestPB(url: EndPoint.danmakuWebView, parameters: ["type": 1, "oid": cid])
    }

    static func requestDanmakuList(cid: Int, segmentIdx: Int) async throws -> DmSegMobileReply {
        try await requestPB(url: EndPoint.danmakuList, parameters: ["type": 1, "oid": cid, "segment_index": segmentIdx])
    }
}

// MARK: - User

extension WebRequest {
    static func follow(mid: Int, follow: Bool) async throws {
        try await requestVoid(method: .post, url: EndPoint.relationModify, parameters: ["fid": mid, "act": follow ? 1 : 2, "re_src": 14])
    }

    static func block(mid: Int, block: Bool) async throws {
        try await requestVoid(method: .post, url: EndPoint.relationModify, parameters: ["fid": mid, "act": block ? 5 : 6, "re_src": 14])
    }

    struct UpSpaceInfo: Codable, Hashable {
        let name: String
        let sign: String
        let face: URL?
        let is_followed: Bool
        let is_risk: Bool
    }

    static func requestUpSpaceInfo(mid: Int) async throws -> UpSpaceInfo {
        let param: Parameters = ["mid": mid]
        let resp: UpSpaceInfo = try await request(method: .get, url: EndPoint.spaceAccInfo, parameters: param)
        return resp
    }

    struct UpSpaceRelation: Codable, Hashable {
        // 0：未关注 1：悄悄关注（已弃用）2：已关注 6：已互粉 128：已拉黑
        let attribute: Int

        var is_blocked: Bool {
            return attribute == 128
        }
    }

    static func requestUpSpaceRelation(mid: Int) async throws -> UpSpaceRelation {
        struct Resp: Codable {
            let relation: UpSpaceRelation
        }

        let param: Parameters = ["mid": mid]
        let resp: Resp = try await request(method: .get, url: EndPoint.spaceAccRelation, parameters: param)
        return resp.relation
    }

    static func logout() async {
        do {
            _ = try await request(method: .post, url: EndPoint.logout) as [String: String]
            Logger.debug("logout success")
        } catch {
            Logger.warn("logout fail: \(error)")
        }
        CookieHandler.shared.removeCookie()
    }

    struct NavInfo: Codable {
        let mid: Int
        let uname: String
        let face: String
    }

    static func requestLoginInfo(accessKey: String? = nil) async throws -> NavInfo {
        var parameters: [String: Any] = [:]
        if let accessKey {
            parameters["access_key"] = accessKey
        }
        return try await request(url: EndPoint.nav, parameters: parameters)
    }
}

extension WebRequest.UpSpaceInfo: AvatarProviding {
    var avatar: URL? { face }
}

extension URL {
    func addSchemeIfNeed() -> URL {
        if scheme == nil {
            return URL(string: "https:\(absoluteString)")!
        }
        return self
    }
}
