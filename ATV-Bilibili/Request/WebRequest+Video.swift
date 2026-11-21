//
//  WebRequest+Video.swift
//  ATV-Bilibili
//
//  从 WebRequest.swift 按既有 MARK 蓝图拆出（审核报告 ATV P2：WebRequest 已有
//  拆分注释未完成），纯迁移零行为变化。核心管线仍在 WebRequest.swift。
//

import Alamofire
import Foundation
import SwiftProtobuf

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

    /// 点赞 / 取消点赞。抛错交给调用方展示（用户显式动作，静默失败最伤信任）
    static func requestLike(aid: Int, like: Bool) async throws {
        try await requestVoid(method: .post, url: EndPoint.like, parameters: ["aid": aid, "like": like ? "1" : "2"])
    }

    /// 该接口 data 直接是 0/1
    static func requestLikeStatus(aid: Int) async -> Bool {
        let liked: Int? = try? await request(url: EndPoint.likeStatus, parameters: ["aid": aid])
        return liked == 1
    }

    /// 投币（select_like=1 顺带点赞）。抛错交给调用方展示
    static func requestCoin(aid: Int, num: Int) async throws {
        try await requestVoid(method: .post, url: EndPoint.coin, parameters: ["aid": aid, "multiply": num, "select_like": 1])
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
        var failures = [String]()
        if !isLiked {
            do {
                try await requestLike(aid: aid, like: true)
                done.append("点赞")
            } catch {
                failures.append("点赞失败（\(error.localizedDescription)）")
            }
        }
        if multiply == 0 {
            do {
                try await requestCoin(aid: aid, num: 1)
                done.append("投币")
            } catch {
                failures.append("投币失败（\(error.localizedDescription)）")
            }
        }
        if !isFavoured {
            // 此前 requestFavorite 是 fire-and-forget，请求还没发就先报「已收藏」；
            // 现在等结果，失败如实进 failures。收藏夹列表拉取失败也不能静默跳过。
            do {
                if let folder = try await requestFavVideosList().first {
                    try await requestFavorite(aid: aid, mid: folder.id)
                    done.append("收藏至「\(folder.title)」")
                } else {
                    failures.append("收藏失败（没有可用的自建收藏夹）")
                }
            } catch {
                failures.append("收藏失败（\(error.localizedDescription)）")
            }
        }

        return formattedTripleResult(done: done, failures: failures)
    }

    private static func formattedTripleResult(done: [String], failures: [String]) -> String {
        let success = done.isEmpty ? "" : "已\(done.joined(separator: "、"))"
        let failed = failures.joined(separator: "；")
        switch (success.isEmpty, failed.isEmpty) {
        case (true, true): return "已经三连过啦"
        case (true, false): return failed
        case (false, true): return success
        case (false, false): return "\(success)；\(failed)"
        }
    }

    /// 该接口没有外层 code/data 包装；直接解析顶层 number，
    /// 不能再走 request(dataObj: "")——那会恒返回 "null" 并解码失败成 0。
    static func requestTodayCoins() async -> Int {
        struct Resp: Decodable {
            let number: Int?
        }
        guard let raw = try? await requestData(url: EndPoint.accountExp),
              let resp = try? JSONDecoder().decode(Resp.self, from: raw)
        else { return 0 }
        return resp.number ?? 0
    }

    /// 收藏/取消收藏改为 async throws：此前 fire-and-forget + try? 吞错，
    /// 网络失败时 UI 状态与服务器永久不一致且用户无感知（点赞/投币早就有回滚+提示，这两组双标了）
    static func requestFavorite(aid: Int, mid: Int) async throws {
        try await requestVoid(method: .post, url: EndPoint.favResourceDeal, parameters: ["rid": aid, "type": 2, "add_media_ids": mid])
    }

    static func removeFavorite(aid: Int, mid: [Int]) async throws {
        try await requestVoid(method: .post, url: EndPoint.favResourceDeal, parameters: ["rid": aid, "type": 2, "del_media_ids": mid.map { "\($0)" }.joined(separator: ",")])
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
        let rawServer = Settings.areaLimitCustomServer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawServer.isEmpty else { throw ValidationError.argumentInvalid(message: "未设置解析服务器") }

        // 自定义解析服务器会把请求带出 B 站域名，绝不允许明文；也不发送 access_key。
        let serverString = rawServer.contains("://") ? rawServer : "https://\(rawServer)"
        guard let serverComponents = URLComponents(string: serverString),
              serverComponents.scheme?.lowercased() == "https",
              let serverHost = serverComponents.host, !serverHost.isEmpty,
              let baseComponents = URLComponents(string: EndPoint.pcgPlayUrl)
        else {
            throw ValidationError.argumentInvalid(message: "解析服务器必须使用 HTTPS 且包含有效域名")
        }
        var components = baseComponents
        components.host = serverHost
        components.port = serverComponents.port
        if !serverComponents.path.isEmpty, serverComponents.path != "/" {
            let prefix = serverComponents.path.hasSuffix("/")
                ? String(serverComponents.path.dropLast())
                : serverComponents.path
            components.path = prefix + baseComponents.path
        }
        guard let url = components.url else {
            throw ValidationError.argumentInvalid(message: "解析服务器地址无效")
        }

        // 解析服务器必须使用ep_id参数，不能使用avid参数，解析服务器一般有缓存，area和ep_id必须保持一致，要不然会被缓存拦截
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
        // 非 bilibili.com 主机不携带登录 token：解析服务器只需要 ep/cid/area。
        // 必须写成精确域名或 `.bilibili.com` 子域，`evilbilibili.com` 不能命中。
        let normalizedHost = serverHost.lowercased()
        if normalizedHost == "bilibili.com" || normalizedHost.hasSuffix(".bilibili.com"),
           let access_key = ApiRequest.getToken()?.accessToken
        {
            parameters["access_key"] = access_key
        }
        parameters["appkey"] = ApiRequest.appkey
        parameters["local_id"] = 0
        parameters["mobi_app"] = "android"

        return try await request(url: url,
                                 parameters: parameters,
                                 dataObj: "result")
    }

    /// sort: 0=按时间(最新) 1=按点赞(热门)；页码从 1 开始。
    static func requestReplys(aid: Int, sort: Int = 1, page: Int = 1, pageSize: Int = 20) async throws -> Replys {
        try await request(url: EndPoint.reply,
                          parameters: [
                              "type": 1,
                              "oid": aid,
                              "sort": sort,
                              "nohot": sort == 1 ? 0 : 1,
                              "pn": page,
                              "ps": pageSize,
                          ])
    }

    static func requestSubtitle(url: URL) async throws -> [SubtitleContent] {
        struct SubtitleContentResp: Codable {
            let body: [SubtitleContent]
        }
        // 走 BLSession（10s 超时）而非 Alamofire 默认会话（60s），并带上 UA/Referer：
        // B 站字幕 CDN 目前不校验所以「能跑」，一旦校验 Referer 会静默拿不到字幕且难排查
        let headers: HTTPHeaders = [
            "User-Agent": Keys.userAgent,
            "Referer": Keys.referer,
        ]
        let resp = try await BLSession.default.request(url, headers: headers).serializingDecodable(SubtitleContentResp.self).value
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
