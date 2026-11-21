//
//  BilibiliCredential.swift
//  ATV-Bilibili
//
//  B 站 App 接口凭据（appkey / appsec）。
//
//  来源：这两个值是 B 站**公开 TV 客户端**的固定凭据 —— 随客户端分发、写在客户端里，
//  不是用户账号密钥，也不是本项目新增的 secret。原实现直接硬编码在 ApiRequest.swift，
//  现在改成「配置优先、缺省回落」：
//    1) 先读 Info.plist 的 BilibiliAppKey / BilibiliAppSecret
//       （值由构建变量 \$(BILIBILI_APPKEY) / \$(BILIBILI_APPSECRET) 注入，
//        可以在命令行或 CI 里覆盖，不需要改仓库文件）
//    2) 没有配置（键缺失 / 空串 / 变量未展开）时回落到下面的公开常量
//  这样既能换用自己的 appkey，又不需要把任何新密钥写进仓库。
//

import Foundation

enum BilibiliCredential {
    /// B 站公开 TV 端客户端的 appkey（= 原 ApiRequest.swift 第 21 行的值，行为不变）
    static let publicAppKey = "5ae412b53418aac5"
    /// 与 publicAppKey 配套的 appsec，只参与请求签名
    static let publicAppSecret = "5b9cf6c9786efd204dcf0c1ce2d08436"

    /// 实际生效的 appkey
    static let appKey = resolve(value: bundleValue("BilibiliAppKey"), fallback: publicAppKey)
    /// 实际生效的 appsec
    static let appSecret = resolve(value: bundleValue("BilibiliAppSecret"), fallback: publicAppSecret)

    /// 纯函数：归一 Info.plist 里读到的原始值。
    /// 未配置时 Info.plist 里会留下未展开的 "$(BILIBILI_APPKEY)" 或空串，两者都算未配置。
    static func resolve(value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return fallback }
        return trimmed
    }

    private static func bundleValue(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
