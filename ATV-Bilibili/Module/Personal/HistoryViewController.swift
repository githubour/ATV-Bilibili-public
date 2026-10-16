//
//  HistoryViewController.swift
//  ATV-Bilibili
//
//  Created by whw on 2021/4/15.
//

import UIKit

/// 历史记录页：与其他 Tab 页统一走 StandardVideoCollectionViewController 基类，
/// 列表/焦点/选中跳转均由基类提供；历史接口无分页，禁用下拉加载。
class HistoryViewController: StandardVideoCollectionViewController<HistoryData> {
    override func supportPullToLoad() -> Bool {
        return false
    }

    override func request(page: Int) async throws -> [HistoryData] {
        try await WebRequest.requestHistory()
    }
}
