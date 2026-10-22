//
//  VideoDetailViewController.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2021/4/17.
//

import AVKit
import Combine
import Foundation
import UIKit

import Alamofire
import Kingfisher
import MarqueeLabel
import SnapKit
import TVUIKit

private struct PageRange {
    let startIndex: Int
    let endIndex: Int

    var title: String {
        "\(startIndex + 1) - \(endIndex + 1)"
    }
}

class VideoDetailViewController: UIViewController {
    @IBOutlet var backgroundImageView: UIImageView!
    @IBOutlet var effectContainerView: UIVisualEffectView!
    @IBOutlet var titleLabel: UILabel!
    @IBOutlet var upButton: BLCustomTextButton!
    @IBOutlet var followButton: BLCustomButton!
    @IBOutlet var coverImageView: UIImageView!
    @IBOutlet var playButton: BLCustomButton!
    @IBOutlet var likeButton: BLCustomButton!
    @IBOutlet var coinButton: BLCustomButton!
    @IBOutlet var noteView: NoteDetailView!
    @IBOutlet var dislikeButton: BLCustomButton!
    @IBOutlet var actionButtonSpaceView: UIView!
    @IBOutlet var durationLabel: UILabel!
    @IBOutlet var playCountLabel: UILabel!
    @IBOutlet var danmakuLabel: UILabel!
    @IBOutlet var uploadTimeLabel: UILabel!
    @IBOutlet var bvidLabel: UILabel!
    @IBOutlet var followersLabel: UILabel!
    @IBOutlet var avatarImageView: UIImageView!
    @IBOutlet var favButton: BLCustomButton!
    @IBOutlet var pageCollectionView: UICollectionView!
    @IBOutlet var recommandCollectionView: UICollectionView!
    @IBOutlet var replysCollectionView: UICollectionView!
    @IBOutlet var repliesCollectionViewHeightConstraints: NSLayoutConstraint!
    @IBOutlet var ugcCollectionView: UICollectionView!
    @IBOutlet var pageView: UIView!
    @IBOutlet var ugcLabel: UILabel!
    @IBOutlet var ugcView: UIView!

    private var loadingView = UIActivityIndicatorView()

    private var pageCollectionViewTopToTitleConstraint: Constraint?
    private var pageCollectionViewTopToRangeConstraint: Constraint?
    private let pageRangeSize = 20
    private var pageRanges = [PageRange]()
    private lazy var pageRangeCollectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: makePageRangeCollectionViewLayout())
        collectionView.register(BLTextOnlyCollectionViewCell.self)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        collectionView.isHidden = true
        return collectionView
    }()

    private var epid = 0
    private var seasonId = 0
    private var aid = 0
    private var cid = 0
    private var lastPlayCid: Int?
    private var playTimeInSecond: Int?
    private var subType: Int?
    private var data: VideoDetail?
    /// 详情页已经拉到的播放信息：起播时传给播放器，省一次重复请求。
    private var detailPlayerInfo: PlayerInfo?
    /// 详情加载代次：快速连点相关视频时，只允许最后一次请求写 UI/播放器。
    private var loadGeneration = 0
    private var fetchTask: Task<Void, Never>?
    @IBOutlet var scrollView: UIScrollView!
    private var didSentCoins = 0 {
        didSet {
            if didSentCoins > 0 {
                coinButton.isOn = true
            }
        }
    }

    private var isBangumi = false
    private var pages = [VideoPage]()
    private var replys: Replys?

    private var allUgcEpisodes = [VideoDetail.Info.UgcSeason.UgcVideoInfo]()

    private var cancellables = Set<AnyCancellable>()

    private static func instantiate() -> VideoDetailViewController {
        let identifier = String(describing: VideoDetailViewController.self)
        guard let vc = UIStoryboard(name: "Main", bundle: .main)
            .instantiateViewController(identifier: identifier) as? VideoDetailViewController
        else {
            fatalError("Main.storyboard 缺少 identifier 为 \(identifier) 的页面")
        }
        return vc
    }

    static func create(aid: Int, cid: Int?, epid: Int? = nil) -> VideoDetailViewController {
        let vc = instantiate()
        vc.aid = aid
        vc.cid = cid ?? 0
        vc.epid = epid ?? 0
        return vc
    }

    static func create(epid: Int) -> VideoDetailViewController {
        let vc = instantiate()
        vc.epid = epid
        return vc
    }

    static func create(seasonId: Int) -> VideoDetailViewController {
        let vc = instantiate()
        vc.seasonId = seasonId
        return vc
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        pageCollectionView.register(BLTextOnlyCollectionViewCell.self)
        pageCollectionView.collectionViewLayout = makePageCollectionViewLayout()
        pageCollectionView.clipsToBounds = false
        setupPageRangeCollectionView()
        recommandCollectionView.register(RelatedVideoCell.self)
        ugcCollectionView.register(RelatedVideoCell.self)
        recommandCollectionView.collectionViewLayout = makeRelatedVideoCollectionViewLayout()
        ugcCollectionView.collectionViewLayout = makeRelatedVideoCollectionViewLayout()
        noteView.onPrimaryAction = {
            [weak self] note in
            let detail = ContentDetailViewController.createDesp(content: note.label.text ?? "")
            self?.present(detail, animated: true)
        }

        var focusGuide = UIFocusGuide()
        view.addLayoutGuide(focusGuide)
        NSLayoutConstraint.activate([
            focusGuide.topAnchor.constraint(equalTo: upButton.topAnchor),
            focusGuide.leftAnchor.constraint(equalTo: followButton.rightAnchor),
            focusGuide.rightAnchor.constraint(equalTo: coverImageView.leftAnchor),
            focusGuide.bottomAnchor.constraint(equalTo: upButton.bottomAnchor),
        ])
        focusGuide.preferredFocusEnvironments = [followButton]

        focusGuide = UIFocusGuide()
        view.addLayoutGuide(focusGuide)
        NSLayoutConstraint.activate([
            focusGuide.topAnchor.constraint(equalTo: actionButtonSpaceView.topAnchor),
            focusGuide.leftAnchor.constraint(equalTo: actionButtonSpaceView.leftAnchor),
            focusGuide.rightAnchor.constraint(equalTo: actionButtonSpaceView.rightAnchor),
            focusGuide.bottomAnchor.constraint(equalTo: actionButtonSpaceView.bottomAnchor),
        ])
        focusGuide.preferredFocusEnvironments = [dislikeButton]

        replysCollectionView.publisher(for: \.contentSize).sink { [weak self] newSize in
            self?.repliesCollectionViewHeightConstraints.constant = newSize.height
            self?.view.setNeedsLayout()
        }.store(in: &cancellables)

        reloadData()
    }

    override var preferredFocusedView: UIView? {
        return playButton
    }

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

    private static let pageSectionTitleIdentifier = "pageSectionTitleLabel"

    private func setupPageRangeCollectionView() {
        guard let titleLabel = pageView.subviews
            .compactMap({ $0 as? UILabel })
            .first(where: { $0.accessibilityIdentifier == Self.pageSectionTitleIdentifier })
        else {
            Logger.warn("找不到「视频选集」标题，跳过分段时间轴布局")
            return
        }

        pageView.addSubview(pageRangeCollectionView)

        let storyboardTopConstraints = pageView.constraints.filter { constraint in
            (constraint.firstItem as? UICollectionView) === pageCollectionView && constraint.firstAttribute == .top
        }
        storyboardTopConstraints.forEach { $0.isActive = false }

        let storyboardHeightConstraints = (pageView.constraints + pageCollectionView.constraints).filter { constraint in
            (constraint.firstItem as? UICollectionView) === pageCollectionView && constraint.firstAttribute == .height
        }
        storyboardHeightConstraints.forEach { $0.isActive = false }

        pageRangeCollectionView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalTo(titleLabel.snp.bottom).offset(30)
            make.height.equalTo(90)
        }
        pageCollectionView.snp.makeConstraints { make in
            pageCollectionViewTopToTitleConstraint = make.top.equalTo(titleLabel.snp.bottom).offset(30).constraint
            pageCollectionViewTopToRangeConstraint = make.top.equalTo(pageRangeCollectionView.snp.bottom).offset(30).constraint
            make.height.equalTo(150)
        }
        pageCollectionViewTopToRangeConstraint?.deactivate()
    }

    private func updatePageRanges() {
        guard pages.count >= pageRangeSize else {
            pageRanges = []
            setPageRangeCollectionViewHidden(true)
            return
        }

        pageRanges = stride(from: 0, to: pages.count, by: pageRangeSize).map { startIndex in
            PageRange(startIndex: startIndex, endIndex: min(startIndex + pageRangeSize, pages.count) - 1)
        }
        setPageRangeCollectionViewHidden(false)
    }

    private func setPageRangeCollectionViewHidden(_ isHidden: Bool) {
        pageRangeCollectionView.isHidden = isHidden
        if isHidden {
            pageCollectionViewTopToRangeConstraint?.deactivate()
            pageCollectionViewTopToTitleConstraint?.activate()
        } else {
            pageCollectionViewTopToTitleConstraint?.deactivate()
            pageCollectionViewTopToRangeConstraint?.activate()
        }
    }

    private func setupLoading() {
        effectContainerView.isHidden = true
        view.addSubview(loadingView)
        loadingView.color = .white
        loadingView.style = .large
        loadingView.startAnimating()
        loadingView.makeConstraintsBindToCenterOfSuperview()
    }

    func present(from vc: UIViewController, directlyEnterVideo: Bool = Settings.directlyEnterVideo) {
        modalPresentationStyle = .custom
        transitioningDelegate = BLTransition.shared
        if !directlyEnterVideo {
            vc.present(self, animated: true)
        } else {
            vc.present(self, animated: true) { [weak self] in
                guard let self else { return }
                let player = self.makeVideoPlayer(for: PlayInfo(aid: self.aid, cid: self.cid, epid: self.epid, seasonId: isBangumi ? self.seasonId : nil, lastPlayCid: self.lastPlayCid, playTimeInSecond: self.playTimeInSecond))
                self.present(player, animated: true)
            }
        }
    }

    private func exit(with error: Error) {
        presentError(error, title: "获取失败", dismissSelf: true)
    }

    /// 站内换片/首屏加载统一入口：取消上一轮请求，避免旧响应覆盖新视频。
    private func reloadData() {
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            await self?.fetchData()
        }
    }

    private func fetchData() async {
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
            guard let self else { return }
            do {
                let replys = try await WebRequest.requestReplys(aid: requestedAid)
                guard !Task.isCancelled, generation == self.loadGeneration, self.aid == requestedAid else { return }
                self.replys = replys
                self.replysCollectionView.reloadData()
            } catch {
                Logger.warn(error)
            }
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
        }

        if isBangumi {
            favButton.isHidden = true
            recommandCollectionView.superview?.isHidden = true
            return
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
        if Settings.continuePlay {
            if let lastPlayCid, lastPlayCid == cid {
                playButton.title = "继续播放"
            } else {
                playButton.title = "播放"
            }
        }

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

    /// 详情页起播/分 P：把已取到的 detail/playerInfo 传给播放器；只在同一 aid/cid 时复用，避免串集。
    private func makeVideoPlayer(for playInfo: PlayInfo) -> VideoPlayerViewController {
        let canSeed = playInfo.aid == aid && (playInfo.cid ?? 0) == cid
        return VideoPlayerViewController(playInfo: playInfo,
                                         initialDetail: data,
                                         initialPlayerInfo: canSeed ? detailPlayerInfo : nil)
    }

    @IBAction func actionPlay(_ sender: Any) {
        let player = makeVideoPlayer(for: PlayInfo(aid: aid, cid: cid, epid: epid, seasonId: seasonId, subType: subType, lastPlayCid: lastPlayCid, playTimeInSecond: playTimeInSecond, title: data?.title))
        if pages.count > 0, let index = pages.firstIndex(where: { $0.cid == cid }) {
            let seq = pages.map({ PlayInfo(aid: aid, cid: $0.cid, epid: $0.epid, seasonId: seasonId, subType: subType, title: $0.part) })
            if seq.count > 0 {
                player.sequenceProvider = VideoSequenceProvider(seq: seq, currentIndex: index, kind: .episodes)
            }
        }
        if allUgcEpisodes.count > 0, let index = allUgcEpisodes.firstIndex(where: { $0.cid == cid }) {
            let seq = allUgcEpisodes.map({ PlayInfo(aid: $0.aid, cid: $0.cid, title: $0.title) })
            if seq.count > 0 {
                player.sequenceProvider = VideoSequenceProvider(seq: seq, currentIndex: index, kind: .ugcCollection)
            }
        }
        present(player, animated: true, completion: nil)
    }

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
}

extension VideoDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        switch collectionView {
        case pageRangeCollectionView:
            let range = pageRanges[indexPath.item]
            pageCollectionView.scrollToItem(at: IndexPath(item: range.startIndex, section: 0), at: .left, animated: true)
        case pageCollectionView:
            let page = pages[indexPath.item]
            let player = makeVideoPlayer(for: PlayInfo(aid: isBangumi ? page.page : aid, cid: page.cid, epid: page.epid, seasonId: seasonId, subType: subType, lastPlayCid: lastPlayCid, playTimeInSecond: playTimeInSecond, title: page.part))

            let seq = pages.map({ PlayInfo(aid: isBangumi ? $0.page : aid, cid: $0.cid, epid: $0.epid, seasonId: seasonId, subType: subType, title: $0.part) })
            if seq.count > 0 {
                player.sequenceProvider = VideoSequenceProvider(seq: seq, currentIndex: indexPath.item, kind: .episodes)
            }
            present(player, animated: true, completion: nil)
        case replysCollectionView:
            guard let reply = replys?.replies?[indexPath.item] else { return }
            let detail = ReplyDetailViewController(reply: reply)
            present(detail, animated: true)
        case ugcCollectionView:
            let video = allUgcEpisodes[indexPath.item]
            if Settings.showRelatedVideoInCurrentVC {
                aid = video.aid
                cid = video.cid
                // UGC 合集是普通视频：必须清掉上一页可能残留的番剧标识，否则 fetchData 会走错分支。
                epid = 0
                seasonId = 0
                isBangumi = false
                subType = nil
                reloadData()
            } else {
                let detailVC = VideoDetailViewController.create(aid: video.aid, cid: video.cid)
                detailVC.present(from: self)
            }
        case recommandCollectionView:
            if let video = data?.Related[indexPath.item] {
                if Settings.showRelatedVideoInCurrentVC {
                    aid = video.aid
                    cid = video.cid
                    epid = 0
                    seasonId = 0
                    isBangumi = false
                    subType = nil
                    reloadData()
                } else {
                    let detailVC = VideoDetailViewController.create(aid: video.aid, cid: video.cid)
                    detailVC.present(from: self)
                }
            }
        default:
            break
        }
    }
}

extension VideoDetailViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        switch collectionView {
        case pageRangeCollectionView:
            return pageRanges.count
        case pageCollectionView:
            return pages.count
        case replysCollectionView:
            return replys?.replies?.count ?? 0
        case ugcCollectionView:
            return allUgcEpisodes.count
        case recommandCollectionView:
            return data?.Related.count ?? 0
        default:
            return 0
        }
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        switch collectionView {
        case pageRangeCollectionView:
            let cell = collectionView.dequeue(BLTextOnlyCollectionViewCell.self, for: indexPath)
            cell.titleLabel.text = pageRanges[indexPath.item].title
            return cell
        case pageCollectionView:
            let cell = collectionView.dequeue(BLTextOnlyCollectionViewCell.self, for: indexPath)
            let page = pages[indexPath.item]
            cell.titleLabel.text = page.part
            return cell
        case replysCollectionView:
            let cell = collectionView.dequeue(ReplyCell.self, for: indexPath)
            if let reply = replys?.replies?[indexPath.item] {
                cell.config(replay: reply)
            }
            return cell
        case ugcCollectionView:
            let cell = collectionView.dequeue(RelatedVideoCell.self, for: indexPath)
            let record = allUgcEpisodes[indexPath.row]
            cell.update(data: record)
            return cell
        case recommandCollectionView:
            let cell = collectionView.dequeue(RelatedVideoCell.self, for: indexPath)
            if let related = data?.Related[indexPath.row] {
                cell.update(data: related)
            }
            return cell
        default:
            return UICollectionViewCell()
        }
    }
}

extension VideoDetailViewController {
    func makePageCollectionViewLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout {
            _, _ in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                  heightDimension: .fractionalHeight(1.0))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(widthDimension: .absolute(300), heightDimension: .absolute(150))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.orthogonalScrollingBehavior = .continuous
            section.interGroupSpacing = 40
            return section
        }
    }

    func makePageRangeCollectionViewLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout {
            _, _ in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                  heightDimension: .fractionalHeight(1.0))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(widthDimension: .absolute(200), heightDimension: .fractionalHeight(1))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.orthogonalScrollingBehavior = .continuous
            section.interGroupSpacing = 40
            return section
        }
    }

    func makeRelatedVideoCollectionViewLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout {
            _, _ in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                  heightDimension: .estimated(200))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(0.18), heightDimension: .estimated(200))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = .init(top: 40, leading: 0, bottom: 0, trailing: 0)
            section.orthogonalScrollingBehavior = .continuous
            section.interGroupSpacing = 40
            return section
        }
    }
}
