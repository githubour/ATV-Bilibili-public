//
//  APIResponse.swift
//  ATV-Bilibili
//
//  B 站接口统一外层结构 {"code": Int, "message": String, "data": ...} 的解析，
//  用 Foundation 的 JSONSerialization 实现，避免为取一个 code 引入额外依赖。
//

import Foundation

enum APIResponse {
    struct Status {
        let code: Int
        let message: String
    }

    /// 解析外层状态码；响应不是对象（例如纯数组）时返回 nil，视作成功
    static func status(from data: Data) -> Status? {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = dict["code"] as? Int
        else { return nil }
        return Status(code: code, message: dict["message"] as? String ?? "")
    }

    /// 按路径逐层取出字符串，任一层缺失或类型不符返回 ""
    static func string(from data: Data, path: String...) -> String {
        var current: Any? = try? JSONSerialization.jsonObject(with: data)
        for key in path {
            current = (current as? [String: Any])?[key]
        }
        return current as? String ?? ""
    }

    /// 取出 dataObj 对应的子数据并重新序列化，供 JSONDecoder 使用。
    /// dataObj 为空、字段缺失或为 null 时统一返回 "null"
    static func extractDataObject(from data: Data, dataObj: String) throws -> Data {
        guard !dataObj.isEmpty,
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = dict[dataObj], !(value is NSNull)
        else { return Data("null".utf8) }
        // data 可能是顶层标量 (如点赞状态接口 data 直接是 0/1)，
        // 必须加 .fragmentsAllowed，否则 NSJSONSerialization 抛 ObjC 异常直接闪退
        return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }
}
