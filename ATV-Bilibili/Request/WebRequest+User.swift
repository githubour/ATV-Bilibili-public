//
//  WebRequest+User.swift
//  ATV-Bilibili
//
//  从 WebRequest.swift 按既有 MARK 蓝图拆出（审核报告 ATV P2：WebRequest 已有
//  拆分注释未完成），纯迁移零行为变化。核心管线仍在 WebRequest.swift。
//

import Alamofire
import Foundation
import SwiftProtobuf

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

    /// UP 的合集列表。接口分页混排「合集 + 系列」，这里只回传合集。
    static func requestUpSpaceSeasons(mid: Int, page: Int = 1, pageSize: Int = 20) async throws -> [UpSpaceSeasonMeta] {
        let resp: UpSpaceSeasonsResponse = try await request(
            method: .get,
            url: EndPoint.spaceSeasonsList,
            parameters: ["mid": mid, "page_num": page, "page_size": pageSize]
        )
        return resp.items_lists.seasons_list.map(\.meta)
    }

    /// 某个合集内的视频分页。接口不返回 cid，交给详情页解析。
    static func requestUpSpaceSeasonArchives(mid: Int,
                                             seasonId: Int,
                                             page: Int = 1,
                                             pageSize: Int = 20) async throws -> [SeasonArchive]
    {
        let resp: SeasonArchivesResponse = try await request(
            method: .get,
            url: EndPoint.spaceSeasonArchives,
            parameters: [
                "mid": mid,
                "season_id": seasonId,
                "sort_reverse": "false",
                "page_num": page,
                "page_size": pageSize,
            ]
        )
        return resp.archives
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
