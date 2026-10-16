//
//  TabBarPage.swift
//  ATV-Bilibili
//

import Foundation
import UIKit

enum TabBarPage: String, CaseIterable, Codable {
    case feed
    case hot
    case ranking
    case follows
    case favorite
    case personal
    case search
    case followBangumi
    case followUps
    case toView
    case history
    case weeklyWatch

    var title: String {
        switch self {
        case .feed:
            return "推荐"
        case .hot:
            return "热门"
        case .ranking:
            return "排行榜"
        case .follows:
            return "关注"
        case .favorite:
            return "收藏"
        case .personal:
            return "我的"
        case .search:
            return "搜索"
        case .followBangumi:
            return "追番追剧"
        case .followUps:
            return "关注UP"
        case .toView:
            return "稍后再看"
        case .history:
            return "历史记录"
        case .weeklyWatch:
            return "每周必看"
        }
    }

    var symbolName: String {
        switch self {
        case .feed:
            return "house.fill"
        case .hot:
            return "flame.fill"
        case .ranking:
            return "chart.bar.fill"
        case .follows:
            return "person.2.fill"
        case .favorite:
            return "folder.fill"
        case .personal:
            return "person.crop.circle"
        case .search:
            return "magnifyingglass"
        case .followBangumi:
            return "tv.fill"
        case .followUps:
            return "person.crop.rectangle.stack"
        case .toView:
            return "clock.fill"
        case .history:
            return "clock.arrow.circlepath"
        case .weeklyWatch:
            return "sparkles"
        }
    }

    var isFixedInTabBar: Bool {
        self == .personal
    }

    var requirePresentInPersonalPage: Bool {
        switch self {
        case .favorite, .search:
            return true
        default:
            return false
        }
    }

    static var defaultTabBarPages: [TabBarPage] {
        [.feed, .ranking, .follows, .personal, .search]
    }

    static var allConfigurablePages: [TabBarPage] {
        // 热门已折叠进排行榜页, 不再作为独立页面展示
        return allCases.filter { $0 != .hot }
    }
}
