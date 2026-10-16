//
//  ReplyModels.swift
//  ATV-Bilibili
//

import Foundation

struct Replys: Codable, Hashable {
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
            }
        }

        let member: Member
        let content: Content
        let replies: [Reply]?
    }

    let replies: [Reply]?
}
