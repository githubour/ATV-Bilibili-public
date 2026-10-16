//
//  HotViewController.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/10/26.
//

import UIKit

class HotViewController: StandardVideoCollectionViewController<VideoDetail.Info> {
    override func request(page: Int) async throws -> [VideoDetail.Info] {
        return try await WebRequest.requestHotVideo(page: page).list
    }
}

/// 排行榜页内嵌的热门内容: 侧栏样式, 保留分页加载
class RankingHotContentViewController: HotViewController {
    override func setupCollectionView() {
        collectionVC.styleOverride = .sideBar
        super.setupCollectionView()
    }
}

extension WebRequest {
    static func requestHotVideo(page: Int) async throws -> HotData {
        try await request(url: EndPoint.hot, parameters: ["pn": page, "ps": 40], noCookie: Settings.requestHotWithoutCookie)
    }
}

extension WebRequest.EndPoint {
    static let hot = "https://api.bilibili.com/x/web-interface/popular"
}

struct HotData: Codable {
    let no_more: Bool
    let list: [VideoDetail.Info]
}
