//
//  VideoDetailViewController+DetailData.swift
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

// 详情数据链路：观看进度同步、拉取详情/番剧/评论/点赞状态、落地到界面

extension VideoDetailViewController {
    private func updatePlayProgressIfNeeded(progress: BangumiInfo.UserStatus.Progress?, episode: BangumiInfo.Episode) {
        guard let lastEpId = progress?.last_ep_id,
              let lastTime = progress?.last_time,
              lastEpId == episode.id
        else {
            return
        }
        playTimeInSecond = lastTime
        lastPlayCid = episode.cid
    }

    func fetchData() async {
        loadGeneration += 1
        let generation = loadGeneration
        detailPlayerInfo = nil
        scrollView.setContentOffset(.zero, animated: false)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        backgroundImageView.alpha = 0
        setupLoading()
        pageView.isHidden = true
        setPageRangeCollectionViewHidden(true)
        ugcView.isHidden = true
        do {
            if seasonId > 0 {
                let info = try await WebRequest.requestBangumiInfo(seasonID: seasonId)
                guard !Task.isCancelled, generation == loadGeneration else { return }
                isBangumi = true
                subType = info.type
                if let epi = info.episodes.first(where: { $0.id == info.user_status?.progress?.last_ep_id }) ?? info.episodes.first ?? info.section?.first?.episodes.first {
                    aid = epi.aid
                    cid = epi.cid
                    epid = epi.id
                    updatePlayProgressIfNeeded(progress: info.user_status?.progress, episode: epi)
                }
                pages = info.episodes.map({ VideoPage(cid: $0.cid, page: $0.aid, epid: $0.id, from: "", part: $0.title + " " + $0.long_title) })
            } else if epid > 0 {
                let info = try await WebRequest.requestBangumiInfo(epid: epid)
                guard !Task.isCancelled, generation == loadGeneration else { return }
                isBangumi = true
                seasonId = info.season_id
                subType = info.type
                if let epi = info.findEpisodeById(epid) ?? info.episodes.first {
                    aid = epi.aid
                    cid = epi.cid
                    updatePlayProgressIfNeeded(progress: info.user_status?.progress, episode: epi)
                } else {
                    throw NSError(domain: "get epi fail", code: -1)
                }
                pages = info.episodes.map({ VideoPage(cid: $0.cid, page: $0.aid, epid: $0.id, from: "", part: $0.title + " " + $0.long_title) })
            }
            let data = try await WebRequest.requestDetailVideo(aid: aid)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            self.data = data

            if let redirect = data.View.redirect_url?.lastPathComponent, redirect.starts(with: "ep"), let id = Int(redirect.dropFirst(2)), !isBangumi {
                let info = try await WebRequest.requestBangumiInfo(epid: id)
                guard !Task.isCancelled, generation == loadGeneration else { return }
                isBangumi = true
                epid = id
                seasonId = info.season_id
                subType = info.type
                pages = info.episodes.map({ VideoPage(cid: $0.cid, page: $0.aid, epid: $0.id, from: "", part: $0.title + " " + $0.long_title) })
                if let epi = info.episodes.first(where: { $0.id == epid }) {
                    updatePlayProgressIfNeeded(progress: info.user_status?.progress, episode: epi)
                }
            }
            if !isBangumi {
                let playInfo = try await WebRequest.requestPlayerInfo(aid: aid, cid: cid == 0 ? data.View.cid : cid)
                guard !Task.isCancelled, generation == loadGeneration else { return }
                detailPlayerInfo = playInfo
                if cid == 0 {
                    cid = playInfo.last_play_cid > 0 ? playInfo.last_play_cid : data.View.cid
                }
                if playInfo.last_play_cid == cid, let pages = data.View.pages, pages.contains(where: { $0.cid == cid }) {
                    playTimeInSecond = playInfo.playTimeInSecond
                    lastPlayCid = playInfo.last_play_cid
                }
            }
            guard !Task.isCancelled, generation == loadGeneration else { return }
            update(with: data)
            enterVideoDirectlyIfResolved(detailDataArrived: true)
        } catch let err {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            if case let .statusFail(code, _) = err as? RequestError, code == -404 {
                // 解锁港澳台番剧处理
                if !(await fetchAreaLimitBangumiData()) {
                    self.exit(with: err)
                }
            } else {
                self.exit(with: err)
            }
        }

        guard !Task.isCancelled, generation == loadGeneration else { return }
        let requestedAid = aid
        Task { [weak self] in
            await self?.loadInitialReplies(aid: requestedAid, generation: generation)
        }

        Task { [weak self] in
            guard let self else { return }
            let liked = await WebRequest.requestLikeStatus(aid: requestedAid)
            let coins = await WebRequest.requestCoinStatus(aid: requestedAid)
            guard !Task.isCancelled, generation == self.loadGeneration, self.aid == requestedAid else { return }
            self.likeButton.isOn = liked
            self.didSentCoins = coins
            guard !self.isBangumi else { return }
            let favorite = await WebRequest.requestFavoriteStatus(aid: requestedAid)
            guard !Task.isCancelled, generation == self.loadGeneration, self.aid == requestedAid else { return }
            self.favButton.isOn = favorite
            let inToView = await WebRequest.requestIsInToView(aid: requestedAid)
            guard !Task.isCancelled, generation == self.loadGeneration, self.aid == requestedAid else { return }
            self.toViewButton.isOn = inToView
        }

        if isBangumi {
            favButton.isHidden = true
            toViewButton.isHidden = true
            recommandCollectionView.superview?.isHidden = true
            return
        }
    }

    /// 首屏同时拉热门页与最新页：评论区不再只有热门，合并去重后显示约两页。
    func loadInitialReplies(aid: Int, generation: Int) async {
        isRepliesLoading = true
        async let hotTask: Replys? = try? await WebRequest.requestReplys(aid: aid, sort: 1, page: 1)
        async let latestTask: Replys? = try? await WebRequest.requestReplys(aid: aid, sort: 0, page: 1)
        let (hot, latest) = await(hotTask, latestTask)
        guard !Task.isCancelled, generation == loadGeneration, self.aid == aid else { return }
        isRepliesLoading = false
        if hot == nil, latest == nil {
            Logger.warn("[reply] 热门/最新评论均加载失败 aid=\(aid)")
        }
        hotReplies = hot?.replies ?? []
        latestReplies = latest?.replies ?? []
        replyTotalCount = hot?.page?.count ?? latest?.page?.count
        // latest 失败时从第 1 页重试；成功时接在它后面
        replyNextPage = (latest?.page?.num ?? 0) + 1
        displayedReplies = Replys.merged(hot: hotReplies, latest: latestReplies)
        let pageSize = latest?.page?.size ?? 20
        let fetchedCount = latest?.replies?.count ?? hotReplies.count
        hasMoreReplies = fetchedCount >= pageSize
            && (replyTotalCount.map { displayedReplies.count < $0 } ?? true)
        updateCommentsTitle()
        replysCollectionView.reloadData()
    }

    /// 首次 40 条之外的评论按“最新”逐页追加，评论格末尾的「加载更多」卡触发。
    func loadMoreReplies() {
        guard hasMoreReplies, !isRepliesLoading else { return }
        isRepliesLoading = true
        let aid = self.aid
        let generation = loadGeneration
        let page = replyNextPage
        Task { [weak self] in
            guard let self else { return }
            do {
                let replys = try await WebRequest.requestReplys(aid: aid, sort: 0, page: page)
                guard !Task.isCancelled, generation == self.loadGeneration, self.aid == aid else { return }
                self.isRepliesLoading = false
                self.latestReplies.append(contentsOf: replys.replies ?? [])
                if let total = replys.page?.count { self.replyTotalCount = total }
                let before = self.displayedReplies.count
                self.displayedReplies = Replys.merged(hot: self.hotReplies, latest: self.latestReplies)
                let added = self.displayedReplies.count - before
                self.replyNextPage = page + 1
                let pageSize = replys.page?.size ?? 20
                if let fetched = replys.replies?.count, fetched < pageSize || added == 0 {
                    // 到底或接口重复返回同一页时收口，避免「加载更多」无限循环
                    self.hasMoreReplies = false
                } else if let total = self.replyTotalCount {
                    self.hasMoreReplies = self.displayedReplies.count < total
                } else {
                    self.hasMoreReplies = true
                }
                self.updateCommentsTitle()
                self.replysCollectionView.reloadData()
            } catch {
                self.isRepliesLoading = false
                Logger.warn(error)
                self.replysCollectionView.visibleCells
                    .compactMap { $0 as? ReplyLoadMoreCell }
                    .forEach { $0.setLoading(false) }
            }
        }
    }

    private func fetchAreaLimitBangumiData() async -> Bool {
        guard Settings.areaLimitUnlock else { return false }

        do {
            var info: ApiRequest.BangumiInfo?

            if seasonId > 0 {
                info = try await ApiRequest.requestBangumiInfo(seasonID: seasonId)
            } else if epid > 0 {
                info = try await ApiRequest.requestBangumiInfo(epid: epid)
            }
            guard let info = info else { return false }

            let season = try await WebRequest.requestBangumiSeasonView(seasonID: info.season_id)
            isBangumi = true
            // 补一次 seasonId：港澳台路径可能由 epid 进来（self.seasonId 还是 0），
            // 不补的话分集来源标注查表会全落空
            seasonId = info.season_id
            if let epi = season.episodes.first(where: { $0.ep_id == epid }) ?? season.episodes.first {
                aid = epi.aid
                cid = epi.cid
                pages = season.episodes.filter { $0.section_type == 0 }.map({ VideoPage(cid: $0.cid, page: $0.aid, epid: $0.ep_id, from: "", part: $0.index + " " + ($0.index_title ?? "")) })

                let userEpisodeInfo = try await WebRequest.requestUserEpisodeInfo(epid: epi.ep_id)

                let data = VideoDetail(View: VideoDetail.Info(aid: aid, cid: cid, title: info.title, videos: nil, pic: epi.cover, desc: info.evaluate, owner: VideoOwner(mid: season.up_info.mid, name: season.up_info.uname, face: season.up_info.avatar), pages: nil, dynamic: nil, bvid: epi.bvid, duration: epi.durationSeconds, pubdate: epi.pubdate, ugc_season: nil, redirect_url: nil, stat: VideoDetail.Info.Stat(favorite: info.stat.favorites, coin: info.stat.coins, like: info.stat.likes, share: info.stat.share, danmaku: info.stat.danmakus, view: info.stat.views)), Related: [], Card: VideoDetail.Owner(following: userEpisodeInfo.related_up.first?.is_follow == 1, follower: season.up_info.follower))

                self.data = data
                update(with: data)
                return true
            }

        } catch let err {
            Logger.warn("[detail] \(err)")
        }

        return false
    }

    /// 「直进播放」但 cid 待解析时的收尾：详情数据到手后按真实的 cid / 断点起播。
    /// 番剧/影视/课程留在详情页选集（直进会走错播放接口、也容易选错集）；
    /// 用户这期间已经手动开了播放器或别的弹窗则不再补。
    /// 自身 present 转场还没完成时（isBeingPresented）先不消费标记，等转场结束的 viewDidAppear 再试，
    /// 否则这次起播会被 UIKit 丢弃且标记已没了，只能停在详情页。
    /// - Parameter detailDataArrived: 调用是否发生在详情数据落地之后。落地后 cid 仍为 0
    ///   即解析不出，是定局，消费标记放弃；viewDidAppear 的先行调用（数据未必到手）
    ///   则保留标记，等 fetchData 收尾再决断，慢网络下不丢自动起播。
    func enterVideoDirectlyIfResolved(detailDataArrived: Bool) {
        guard pendingDirectEntry else { return }
        guard !isBeingPresented else { return }
        guard presentedViewController == nil, view.window != nil else {
            pendingDirectEntry = false
            return
        }
        guard !isBangumi, cid > 0 else {
            if detailDataArrived {
                pendingDirectEntry = false
            }
            return
        }
        pendingDirectEntry = false
        enterVideoDirectly()
    }

    private func update(with data: VideoDetail) {
        playCountLabel.text = data.View.stat.view.numberString()
        danmakuLabel.text = data.View.stat.danmaku.numberString()
        followersLabel.text = (data.Card.follower ?? 0).numberString() + "粉丝"
        uploadTimeLabel.text = data.View.date
        bvidLabel.text = data.View.bvid
        coinButton.title = data.View.stat.coin.numberString()
        favButton.title = data.View.stat.favorite.numberString()
        likeButton.title = data.View.stat.like.numberString()

        durationLabel.text = data.View.durationString
        titleLabel.text = data.title
        upButton.title = data.ownerName
        followButton.isOn = data.Card.following

        // 更新播放按钮标题
        updatePlayButtonTitle()

        avatarImageView.kf.setImage(with: data.avatar(size: 240), options: .avatar)

        // 封面按 storyboard 里的 622x350 显示尺寸降采样; 背景图在 UIVisualEffectView 之下(必然被模糊), 降到 960x540 无感
        coverImageView.kf.setImage(with: data.pic, options: .cover(width: 640, height: 360))
        backgroundImageView.kf.setImage(with: data.pic, options: .cover(width: 960, height: 540))
        recommandCollectionView.superview?.isHidden = data.Related.count == 0

        var notes = [String]()
        let status = data.View.dynamic ?? ""
        if status.count > 1, status != data.View.desc {
            notes.append(status)
        }
        notes.append(data.View.desc ?? "")
        noteView.label.text = notes.joined(separator: "\n")
        if !isBangumi {
            pages = data.View.pages ?? []
        }
        updatePageRanges()
        pageRangeCollectionView.reloadData()
        if pages.count > 1 {
            pageCollectionView.reloadData()
            pageView.isHidden = false
            let index = pages.firstIndex { $0.cid == cid } ?? 0
            pageCollectionView.scrollToItem(at: IndexPath(row: index, section: 0), at: .left, animated: false)
            if cid == 0 {
                cid = pages.first?.cid ?? 0
            }
        }
        loadingView.stopAnimating()
        loadingView.removeFromSuperview()
        effectContainerView.isHidden = false
        UIView.animate(withDuration: 0.25) {
            self.backgroundImageView.alpha = 1
        }

        if let season = data.View.ugc_season {
            if season.sections.count > 1 {
                if let section = season.sections.first(where: { section in section.episodes.contains(where: { episode in episode.aid == data.View.aid }) }) {
                    allUgcEpisodes = section.episodes
                }
            } else {
                allUgcEpisodes = season.sections.first?.episodes ?? []
            }
            allUgcEpisodes.sort { $0.arc.ctime < $1.arc.ctime }
        }

        ugcCollectionView.reloadData()
        ugcLabel.text = "合集 \(data.View.ugc_season?.title ?? "")  \(data.View.ugc_season?.sections.first?.title ?? "")"
        ugcView.isHidden = allUgcEpisodes.count == 0
        if allUgcEpisodes.count > 0 {
            ugcCollectionView.scrollToItem(at: IndexPath(item: allUgcEpisodes.map { $0.aid }.firstIndex(of: aid) ?? 0, section: 0), at: .left, animated: false)
        }

        recommandCollectionView.reloadData()
    }

    @IBAction func actionShowUpSpace(_ sender: Any) {
        let upSpaceVC = UpSpaceViewController()
        upSpaceVC.mid = data?.View.owner.mid
        present(upSpaceVC, animated: true)
    }

    @IBAction func actionFollow(_ sender: Any) {
        followButton.isOn.toggle()
        guard let mid = data?.View.owner.mid else { return }
        let follow = followButton.isOn
        Task { [weak self] in
            do {
                try await WebRequest.follow(mid: mid, follow: follow)
            } catch {
                // 失败回滚 + 提示，与 actionLike 同一标准（静默失败最伤信任）
                self?.followButton.isOn = !follow
                self?.presentAlert(title: follow ? "关注失败" : "取消关注失败", message: error.localizedDescription)
            }
        }
    }

    /// 「继续播放」只在续看点就是当前集时出现；播放器回写集号后需要同步刷新。
    func updatePlayButtonTitle() {
        guard Settings.continuePlay else { return }
        playButton.title = (lastPlayCid == cid) ? "继续播放" : "播放"
    }
}
