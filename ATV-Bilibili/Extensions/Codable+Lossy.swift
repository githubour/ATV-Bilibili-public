//
//  Codable+Lossy.swift
//  ATV-Bilibili
//
//  B 站部分接口会把数字字段同时以 Int / String 两种形式返回，
//  用 @LossyInt 标记即可统一兼容，免去每个模型手写 init(from:)。
//

import Foundation

/// 兼容 Int / String 两种返回形式的 Int?
///
/// ```swift
/// struct PlayerArgs: Codable {
///     @LossyInt var aid: Int?
/// }
/// ```
@propertyWrapper
struct LossyInt: Codable, Hashable {
    let wrappedValue: Int?

    init(wrappedValue: Int?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            wrappedValue = value
        } else if let string = try? container.decode(String.self) {
            wrappedValue = Int(string)
        } else {
            wrappedValue = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}
