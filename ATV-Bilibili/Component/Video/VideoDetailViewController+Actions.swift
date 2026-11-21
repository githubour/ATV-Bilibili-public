//
//  VideoDetailViewController+Actions.swift
//  ATV-Bilibili
//
//  从 VideoDetailViewController.swift 按 iPad 分发版的拆分蓝图迁出（审核行动项 #9），零行为变化。
//

import AVKit
import Combine
import Foundation
import UIKit

import Alamofire
import Kingfisher
import SnapKit

// 点赞/投币/收藏/点踩/稍后再看等用户动作（乐观更新 + 失败回滚）

extension VideoDetailViewController {
    @IBAction func actionLike(_ sender: Any) {
        Task {
            if likeButton.isOn {
                likeButton.title? -= 1
            } else {
                likeButton.title? += 1
            }
            likeButton.isOn.toggle()
            let target = likeButton.isOn
            do {
                try await WebRequest.requestLike(aid: aid, like: target)
            } catch {
                // 失败还原状态并说明原因，别静默吞掉（用户显式动作）
                likeButton.isOn = !target
                if likeButton.isOn {
                    likeButton.title? += 1
                } else {
                    likeButton.title? -= 1
                }
                presentAlert(title: "点赞失败", message: error.localizedDescription)
            }
        }
    }

    @IBAction func actionCoin(_ sender: Any) {
        guard didSentCoins < 2 else { return }
        let alert = UIAlertController(title: "投币个数", message: nil, preferredStyle: .actionSheet)
        Task {
            let todayCoins = await WebRequest.requestTodayCoins()
            alert.message = "今日已投(\(todayCoins / 10)/5)个币"
        }
        let aid = aid
        alert.addAction(UIAlertAction(title: "1", style: .default) { [weak self] _ in
            guard let self else { return }
            self.coinButton.title? += 1
            let addedLikeForCoin = !self.likeButton.isOn
            if addedLikeForCoin {
                self.likeButton.title? += 1
                self.likeButton.isOn = true
            }
            self.didSentCoins += 1
            Task { [weak self] in
                do {
                    try await WebRequest.requestCoin(aid: aid, num: 1)
                } catch {
                    await MainActor.run {
                        guard let self else { return }
                        self.coinButton.title? -= 1
                        self.didSentCoins -= 1
                        if addedLikeForCoin {
                            self.likeButton.title? -= 1
                            self.likeButton.isOn = false
                        }
                        self.presentAlert(title: "投币失败", message: error.localizedDescription)
                    }
                }
            }
        })
        if didSentCoins == 0 {
            alert.addAction(UIAlertAction(title: "2", style: .default) { [weak self] _ in
                guard let self else { return }
                self.coinButton.title? += 2
                let addedLikeForCoin = !self.likeButton.isOn
                if addedLikeForCoin {
                    self.likeButton.title? += 1
                    self.likeButton.isOn = true
                }
                self.didSentCoins += 2
                Task { [weak self] in
                    do {
                        try await WebRequest.requestCoin(aid: aid, num: 2)
                    } catch {
                        await MainActor.run {
                            guard let self else { return }
                            self.coinButton.title? -= 2
                            self.didSentCoins -= 2
                            if addedLikeForCoin {
                                self.likeButton.title? -= 1
                                self.likeButton.isOn = false
                            }
                            self.presentAlert(title: "投币失败", message: error.localizedDescription)
                        }
                    }
                }
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    @IBAction func actionFavorite(_ sender: Any) {
        Task { [weak self] in
            guard let self else { return }
            let favList: [FavListData]
            do {
                favList = try await WebRequest.requestFavVideosList()
            } catch {
                self.presentAlert(title: "收藏夹列表获取失败", message: error.localizedDescription)
                return
            }
            let aid = self.aid
            if self.favButton.isOn {
                self.favButton.title? -= 1
                self.favButton.isOn = false
                Task { [weak self] in
                    do {
                        try await WebRequest.removeFavorite(aid: aid, mid: favList.map { $0.id })
                    } catch {
                        self?.favButton.title? += 1
                        self?.favButton.isOn = true
                        self?.presentAlert(title: "取消收藏失败", message: error.localizedDescription)
                    }
                }
                return
            }
            let alert = UIAlertController(title: "收藏", message: nil, preferredStyle: .actionSheet)
            for fav in favList {
                alert.addAction(UIAlertAction(title: fav.title, style: .default) { [weak self] _ in
                    guard let self else { return }
                    self.favButton.title? += 1
                    self.favButton.isOn = true
                    Task { [weak self] in
                        do {
                            try await WebRequest.requestFavorite(aid: aid, mid: fav.id)
                        } catch {
                            self?.favButton.title? -= 1
                            self?.favButton.isOn = false
                            self?.presentAlert(title: "收藏失败", message: error.localizedDescription)
                        }
                    }
                })
            }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            self.present(alert, animated: true)
        }
    }

    @IBAction func actionDislike(_ sender: Any) {
        dislikeButton.isOn.toggle()
        let aid = aid
        let dislike = dislikeButton.isOn
        Task { [weak self] in
            do {
                try await ApiRequest.requestDislike(aid: aid, dislike: dislike)
            } catch {
                self?.dislikeButton.isOn = !dislike
                self?.presentAlert(title: dislike ? "标记不喜欢失败" : "取消不喜欢失败", message: error.localizedDescription)
            }
        }
    }

    /// 稍后再看开关：未加入→加入；已加入→移除。乐观切换，失败回滚并提示
    @IBAction func actionToView(_ sender: Any) {
        toViewButton.isOn.toggle()
        let aid = aid
        let adding = toViewButton.isOn
        Task { [weak self] in
            guard let self else { return }
            do {
                if adding {
                    try await WebRequest.requestToViewAdd(aid: aid)
                } else {
                    try await WebRequest.requestToViewDel(aid: aid)
                }
                self.presentToast(adding ? "已加入稍后再看" : "已从稍后再看移除")
            } catch {
                self.toViewButton.isOn = !adding
                self.presentAlert(title: adding ? "加入稍后再看失败" : "移除稍后再看失败", message: error.localizedDescription)
            }
        }
    }
}
