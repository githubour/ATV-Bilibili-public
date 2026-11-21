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
    @IBOutlet var toViewButton: BLCustomButton!
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
    @IBOutlet var commentsTitleLabel: UILabel!

    var loadingView = UIActivityIndicatorView()

    var pageCollectionViewTopToTitleConstraint: Constraint?
    var pageCollectionViewTopToRangeConstraint: Constraint?
    let pageRangeSize = 20
    var pageRanges = [PageRange]()
    lazy var pageRangeCollectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: makePageRangeCollectionViewLayout())
        collectionView.register(BLTextOnlyCollectionViewCell.self)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        collectionView.isHidden = true
        return collectionView
    }()

    var epid = 0
    var seasonId = 0
    var aid = 0
    var cid = 0
    var lastPlayCid: Int?
    var playTimeInSecond: Int?
    var subType: Int?
    var data: VideoDetail?
    /// 详情页已经拉到的播放信息：起播时传给播放器，省一次重复请求。
    var detailPlayerInfo: PlayerInfo?
    /// 详情加载代次：快速连点相关视频时，只允许最后一次请求写 UI/播放器。
    var loadGeneration = 0
    var fetchTask: Task<Void, Never>?
    @IBOutlet var scrollView: UIScrollView!
    var didSentCoins = 0 {
        didSet {
            if didSentCoins > 0 {
                coinButton.isOn = true
            }
        }
    }

    var isBangumi = false
    var pages = [VideoPage]()

    var hotReplies = [Replys.Reply]()
    var latestReplies = [Replys.Reply]()
    /// 热门页 + 最新页合并后的展示顺序（热门在前，已去重）
    var displayedReplies = [Replys.Reply]()
    var replyTotalCount: Int?
    var replyNextPage = 2
    var hasMoreReplies = false
    var isRepliesLoading = false

    var allUgcEpisodes = [VideoDetail.Info.UgcSeason.UgcVideoInfo]()

    var cancellables = Set<AnyCancellable>()

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
        replysCollectionView.register(ReplyCell.self)
        replysCollectionView.register(ReplyLoadMoreCell.self)
        // 评论列表高度由 KVO 跟随 contentSize 完全展开（无内容可滚），必须显式关掉滚动：
        // tvOS 26+ 焦点引擎会把"可滚动"的嵌套集合视图当滚动容器处理，向下找下一项时
        // 试图滚它而非外层 scrollView——它又无内容可滚，结果焦点卡死在第一行
        replysCollectionView.isScrollEnabled = false
        // 4 列紧凑卡片：在同样的页面高度里比原来 3 列 582×360 多放约一倍评论
        let replyLayout = UICollectionViewFlowLayout()
        replyLayout.itemSize = CGSize(width: 430, height: 270)
        replyLayout.minimumLineSpacing = 16
        replyLayout.minimumInteritemSpacing = 16
        replyLayout.sectionInset = UIEdgeInsets(top: 0, left: 60, bottom: 0, right: 60)
        replysCollectionView.collectionViewLayout = replyLayout
        replysCollectionView.clipsToBounds = false
        updateCommentsTitle()
        configureGlass()
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

    /// 详情页整体换用 Liquid Glass：全屏底材 + 操作胶囊/描述卡/评论卡统一玻璃
    private func configureGlass() {
        // 全屏底材用 .regular：大面积需要实一点的漫射底，.clear 几乎不压背景，
        // 封面细节全透上来会显得花（胶囊/按钮这类小面积仍用 .clear）
        effectContainerView.effect = BLGlass.effect(.regular)
        // 再压一层暗色，把封面当壁纸用，保证白字与卡片层级
        effectContainerView.contentView.backgroundColor = UIColor.black.withAlphaComponent(0.30)
        [
            playButton, likeButton, coinButton, dislikeButton,
            favButton, toViewButton, upButton, followButton,
        ].forEach { $0.backgroundEffect = BLGlass.effect() }
    }

    func updateCommentsTitle() {
        let count = replyTotalCount ?? displayedReplies.count
        let head = count > 0 ? "评论 \(count.numberString())" : "评论"
        let text = NSMutableAttributedString(
            string: head,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .title3),
                .foregroundColor: UIColor.label,
            ]
        )
        if count > 0 {
            text.append(NSAttributedString(
                string: "   热门 + 最新",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 22),
                    .foregroundColor: UIColor.secondaryLabel,
                ]
            ))
        }
        commentsTitleLabel.attributedText = text
    }

    override var preferredFocusedView: UIView? {
        return playButton
    }

    func setupLoading() {
        effectContainerView.isHidden = true
        view.addSubview(loadingView)
        loadingView.color = .white
        loadingView.style = .large
        loadingView.startAnimating()
        loadingView.makeConstraintsBindToCenterOfSuperview()
    }

    /// 直进播放但 cid 还未知（0）时，先停在详情页等 fetchData 解析出真实分 P 再自动起播。
    /// 否则播放器只能拿 pagelist 的第 1P 起播：多 P 稿件跳回 P1、续播断点也会丢。
    var pendingDirectEntry = false

    func present(from vc: UIViewController, directlyEnterVideo: Bool = Settings.directlyEnterVideo) {
        modalPresentationStyle = .custom
        transitioningDelegate = BLTransition.shared
        guard directlyEnterVideo else {
            vc.present(self, animated: true)
            return
        }
        if cid > 0 {
            vc.present(self, animated: true) { [weak self] in
                self?.enterVideoDirectly()
            }
        } else {
            pendingDirectEntry = true
            vc.present(self, animated: true)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 直进起播若因撞上自身 present 转场被搁置（enterVideoDirectlyIfResolved 保留了 pendingDirectEntry），
        // 转场结束在这里补一次。数据未必已到手，cid 未解析时保留标记等 fetchData 收尾，
        // 慢网络下不丢自动起播；标记已消费时是空操作
        enterVideoDirectlyIfResolved(detailDataArrived: false)
    }

    func exit(with error: Error) {
        presentError(error, title: "获取失败", dismissSelf: true)
    }

    /// 站内换片/首屏加载统一入口：取消上一轮请求，避免旧响应覆盖新视频。
    func reloadData() {
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            await self?.fetchData()
        }
    }
}
