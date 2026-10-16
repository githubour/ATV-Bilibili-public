//
//  TabBarPageFactory.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2026/3/5.
//

import UIKit

class TabBarPageVCFactory {
    static func createVC(for page: TabBarPage) -> UIViewController {
        let vc: UIViewController
        switch page {
        case .feed:
            vc = RecommendViewController()
        case .hot:
            // 热门已折叠进排行榜(排行榜侧栏内嵌热门子页): case 仅为旧数据 Codable 解码保留,
            // normalize 会把 .hot 剔除, 常规路径到不了这里; 万一到达也映射到排行榜
            vc = RankingViewController()
        case .ranking:
            vc = RankingViewController()
        case .follows:
            vc = FollowsViewController()
        case .favorite:
            vc = FavoriteViewController()
        case .personal:
            let personalVC = PersonalViewController.create()
            personalVC.extendedLayoutIncludesOpaqueBars = true
            vc = personalVC
        case .search:
            let resultVC = SearchResultViewController()
            let searchVC = UISearchController(searchResultsController: resultVC)
            searchVC.searchResultsUpdater = resultVC
            vc = UISearchContainerViewController(searchController: searchVC)
        case .followBangumi:
            vc = FollowBangumiViewController()
        case .followUps:
            vc = FollowUpsViewController()
        case .toView:
            vc = ToViewViewController()
        case .history:
            vc = HistoryViewController()
        case .weeklyWatch:
            vc = WeeklyWatchViewController()
        }

        switch page {
        case .search:
            vc.tabBarItem.image = UIImage(systemName: "magnifyingglass")
            vc.tabBarItem.title = nil
        default:
            vc.tabBarItem.title = page.title
            vc.tabBarItem.image = UIImage(systemName: page.symbolName)
        }
        vc.tabBarItem.accessibilityIdentifier = page.rawValue
        return vc
    }
}
