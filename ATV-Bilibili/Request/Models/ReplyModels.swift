//
//  ReplyModels.swift
//  ATV-Bilibili
//

import Foundation

struct Replys: Codable, Hashable {
    struct Page: Codable, Hashable {
        let count: Int?
        let num: Int?
        let size: Int?
    }

    struct Reply: Codable, Hashable {
        struct Member: Codable, Hashable {
            let uname: String
            let avatar: String
        }

        struct Emote: Codable, Hashable {
            let text: String
            let url: String
        }

        struct JumpUrl: Codable, Hashable {
            let title: String
        }

        struct Content: Codable, Hashable {
            let message: String
            let pictures: [Picture]?
            let emote: [String: Emote]?
            let jump_url: [String: JumpUrl]?

            struct Picture: Codable, Hashable {
                let img_src: String
                /// 原始图片尺寸（B 站部分接口返回）。仅用于布局前预估宽高比、减少首屏跳动；
                /// 缺失时以 Kingfisher 加载后的真实尺寸为准（见 MainReplyCell），不是唯一依据。
                let img_width: Int?
                let img_height: Int?
            }
        }

        let member: Member
        let content: Content
        let replies: [Reply]?
        /// 点赞数（列表接口返回；缺失时按 0 处理）
        let like: Int?
        /// 发布时间戳（秒；缺失时 meta 行不显示时间）
        let ctime: Int?
        /// 评论 id：热门页与最新页合并时按它去重（老接口字段缺失时退回内容指纹）
        var rpid: Int? = nil
        var root: Int? = nil
        var parent: Int? = nil
    }

    var page: Page? = nil
    let replies: [Reply]?

    /// 热门页 + 最新页合并，热门在前，按评论 id 去重。
    static func merged(hot: [Reply], latest: [Reply]) -> [Reply] {
        var seen = Set<String>()
        return (hot + latest).filter { seen.insert($0.dedupeKey).inserted }
    }
}

extension Replys.Reply {
    var dedupeKey: String {
        if let rpid {
            return "rpid:\(rpid)"
        }
        return "legacy:\(member.uname)|\(ctime ?? 0)|\(content.message)"
    }
}
