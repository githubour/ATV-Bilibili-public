//
//  FavoriteViewController.swift
//  ATV-Bilibili
//
//  Created by whw on 2022/10/18.
//
import Foundation
import UIKit

class FavoriteViewController: CategoryViewController {
    static let titleElementKind = "titleElementKind"

    override func viewDidLoad() {
        categories = []
        emptyStateText = "暂无收藏夹"
        super.viewDidLoad()

        Task {
            // 并行拉取 + 失败提示：此前双 try? 吞错且串行 await，
            // 未登录态失效/断网时页面静默渲染成空白，用户视角是「收藏夹丢了」
            do {
                async let own = WebRequest.requestFavVideosList()
                async let collected = WebRequest.requestFavFolderCollectedList()
                let (favList, favFolderCollectedList) = try await(own, collected)

                // 用户创建的收藏夹
                categories = favList.map {
                    return CategoryDisplayModel(title: $0.title, contentVC: FavoriteVideoContentViewController(info: $0))
                }

                // 用户收藏的订阅
                favFolderCollectedList
                    .filter { $0.mid != 0 }
                    .forEach {
                        categories.append(CategoryDisplayModel(title: $0.title, contentVC: FavoriteVideoContentViewController(info: $0)))
                    }

                initTypeCollectionView()
            } catch {
                categories = []
                emptyStateText = "收藏夹加载失败，请稍后重试"
                initTypeCollectionView()
                presentAlert(title: "收藏夹加载失败", message: "\(error.localizedDescription)\n请检查登录状态后重进本页")
            }
        }
    }
}

class FavoriteVideoContentViewController: StandardVideoCollectionViewController<FavData> {
    let info: FavListData
    init(info: FavListData) {
        self.info = info
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setupCollectionView() {
        collectionVC.styleOverride = .sideBar
        super.setupCollectionView()
    }

    override func request(page: Int) async throws -> [FavData] {
        if info.createBySelf {
            return try await WebRequest.requestFavVideos(mid: String(info.id), page: page)
        } else {
            return try await WebRequest.requestFavSeason(seasonId: String(info.id), page: page)
        }
    }

    override func goDetail(with record: FavData) {
        if let seasonId = record.ogv?.season_id {
            // PGC 多集内容直进播放自动选集容易播错集数, 固定先进详情页选集(不受「不显示详情页直接进入视频」影响)
            VideoDetailViewController.create(seasonId: seasonId).present(from: self, directlyEnterVideo: false)
        } else {
            let vc = VideoDetailViewController.create(aid: record.id, cid: 0)
            vc.present(from: UIViewController.topMostViewController())
        }
    }
}
