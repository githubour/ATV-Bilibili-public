//
//  WeeklyWatchViewController.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/11/5.
//

import UIKit

class WeeklyWatchViewController: StandardVideoCollectionViewController<VideoDetail.Info> {
    var list = [WeeklyList]()

    override func setupCollectionView() {
        super.setupCollectionView()
        collectionVC.showHeader = true
    }

    override func supportPullToLoad() -> Bool {
        return false
    }

    override func request(page: Int) async throws -> [VideoDetail.Info] {
        list = try await WebRequest.requestWeeklyWatchList()
        if let item = list.first {
            collectionVC.headerText = "\(item.name)  \(item.subject)"
            let data = try await WebRequest.requestWeeklyWatch(wid: item.number)
            return data
        } else {
            throw NSError(domain: "", code: -1)
        }
    }
}

extension WebRequest {
    static func requestWeeklyWatchList() async throws -> [WeeklyList] {
        struct Resp: Codable {
            let list: [WeeklyList]
        }
        let res: Resp = try await request(url: EndPoint.popularSeriesList)
        return res.list
    }

    static func requestWeeklyWatch(wid: Int) async throws -> [VideoDetail.Info] {
        struct Resp: Codable {
            let list: [VideoDetail.Info]
        }
        let res: Resp = try await request(url: EndPoint.popularSeriesOne, parameters: ["number": wid])
        return res.list
    }
}

struct WeeklyList: Codable {
    let number: Int
    let subject: String
    let name: String
}
