//
//  DateFormatter.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/10/23.
//

import Foundation

extension DateFormatter {
    static let date = {
        let formater = DateFormatter()
        formater.dateFormat = "yyyy-MM-dd"
        return formater
    }()

    /// 解析 B 站接口的 "yyyy-MM-dd HH:mm:ss" 时间串
    static let fullDateTime = makeFixedFormat("yyyy-MM-dd HH:mm:ss")
    /// 解析 B 站接口的 ISO 风格 "yyyy-MM-dd'T'HH:mm:ss" 时间串
    static let bilibiliISODateTime = makeFixedFormat("yyyy-MM-dd'T'HH:mm:ss")
    /// 短日期时间展示 "MM-dd HH:mm"
    static let shortDateTime = makeFixedFormat("MM-dd HH:mm")
    /// 当日时钟展示 "HH:mm:ss"
    static let clockTime = makeFixedFormat("HH:mm:ss")
    /// UPnP/SSDP 的 RFC 1123 日期头
    static let httpDate: DateFormatter = {
        let formatter = makeFixedFormat("E, dd MMM yyyy HH:mm:ss 'GMT'")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        return formatter
    }()

    /// 文件日志行时间戳(本地化模板，仅 DDFileLogger 串行队列使用)
    static let logFileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("YYYY/MM/dd HH:mm:ss:SSS")
        return formatter
    }()

    /// 固定格式统一用 en_US_POSIX：设备日历非公历(佛历等)时系统 locale 会解析失败
    private static func makeFixedFormat(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    static func stringFor(timestamp: Int?) -> String? {
        guard let timestamp = timestamp else { return nil }
        return date.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    /// 将时间戳转换为用户友好的相对时间格式（如"刚刚"、"3分钟前"、"2天前"）
    /// - Parameter timestamp: Unix时间戳（秒）
    /// - Returns: 格式化后的相对时间字符串，如果timestamp为nil则返回nil
    static func relativeTimeStringFor(timestamp: Int?) -> String? {
        guard let timestamp = timestamp else { return nil }

        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let now = Date()
        let timeInterval = now.timeIntervalSince(date)

        // 如果是未来时间，返回具体日期
        if timeInterval < 0 {
            return self.date.string(from: date)
        }

        let seconds = Int(timeInterval)
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        let weeks = days / 7
        let months = days / 30
        let years = days / 365

        switch seconds {
        case 0..<10:
            return "刚刚"
        case 10..<60:
            return "\(seconds)秒前"
        case 60..<3600:
            return "\(minutes)分钟前"
        case 3600..<86400:
            return "\(hours)小时前"
        case 86400..<604800:
            return "\(days)天前"
        case 604800..<2592000:
            return "\(weeks)周前"
        case 2592000..<31536000:
            return "\(months)个月前"
        default:
            return "\(years)年前"
        }
    }
}
