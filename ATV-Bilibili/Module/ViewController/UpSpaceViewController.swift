//
//  UpSpaceViewController.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/10/20.
//

import Kingfisher
import SnapKit
import UIKit

/// 空间页里两个列表（投稿 / 合集）的共同入口，容器切换 Tab 时用它们定位焦点与刷新。
protocol UpSpaceListContent: UIViewController {
    var contentCollectionView: UICollectionView { get }
    func reloadData()
}

/// UP 空间：固定资料头 + 「投稿 | 合集」切换。
class UpSpaceViewController: UIViewController, BLTabBarContentVCProtocol {
    var mid: Int!

    private let headerView = UpSpaceProfileHeaderView()
    private let segmentedControl = UISegmentedControl(items: ["投稿", "合集"])
    private let contentView = UIView()
    private let blockedMessageLabel = UILabel()
    private let loadingView = UIActivityIndicatorView(style: .large)

    private var info: WebRequest.UpSpaceInfo?
    private var isBlocked = false
    private var profileLoaded = false
    private var sortByPlayCount = false

    private var currentListVC: (any UpSpaceListContent)?
    private var videoListVC: UpSpaceVideoListViewController?
    private var seasonListVC: UpSpaceSeasonListViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        configureHeaderCallbacks()
        loadProfile()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // 已拉黑时页面没有任何可聚焦控件（解黑请到网页端处理），交给系统默认处理
        if isBlocked {
            return []
        }
        if let collectionView = currentListVC?.contentCollectionView, !collectionView.isHidden {
            return [collectionView]
        }
        return [segmentedControl]
    }

    // MARK: - UI

    private func setupUI() {
        view.addSubview(headerView)
        headerView.mid = mid
        headerView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(10)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(140)
        }

        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
        // 深色页面上默认样式对比度不足；选中段用白底黑字，普通段用半透明白字。
        segmentedControl.selectedSegmentTintColor = .white
        segmentedControl.setTitleTextAttributes([
            .font: UIFont.systemFont(ofSize: 26, weight: .medium),
            .foregroundColor: UIColor.white.withAlphaComponent(0.75),
        ], for: .normal)
        segmentedControl.setTitleTextAttributes([
            .font: UIFont.systemFont(ofSize: 26, weight: .semibold),
            .foregroundColor: UIColor.black,
        ], for: .selected)
        view.addSubview(segmentedControl)
        segmentedControl.snp.makeConstraints { make in
            make.top.equalTo(headerView.snp.bottom)
            make.leading.equalToSuperview().offset(30)
            make.width.equalTo(360)
            make.height.equalTo(60)
        }

        view.addSubview(contentView)
        contentView.snp.makeConstraints { make in
            make.top.equalTo(segmentedControl.snp.bottom).offset(10)
            make.leading.trailing.bottom.equalToSuperview()
        }

        view.addSubview(blockedMessageLabel)
        blockedMessageLabel.text = "无法查看空间内容，请将该用户移除黑名单"
        blockedMessageLabel.font = UIFont.systemFont(ofSize: 28, weight: .medium)
        blockedMessageLabel.textColor = UIColor(named: "titleColor") ?? .white
        blockedMessageLabel.textAlignment = .center
        blockedMessageLabel.numberOfLines = 0
        blockedMessageLabel.isHidden = true
        blockedMessageLabel.snp.makeConstraints { make in
            make.center.equalTo(contentView)
            make.leading.greaterThanOrEqualToSuperview().offset(40)
            make.trailing.lessThanOrEqualToSuperview().offset(-40)
        }

        view.addSubview(loadingView)
        loadingView.color = .white
        loadingView.style = .large
        loadingView.snp.makeConstraints { make in
            make.center.equalTo(contentView)
        }
        loadingView.startAnimating()
    }

    private func configureHeaderCallbacks() {
        headerView.onSearchTapped = { [weak self] in
            self?.presentSpaceSearch()
        }
        headerView.onSortTapped = { [weak self] byPlayCount in
            guard let self else { return }
            self.sortByPlayCount = byPlayCount
            self.videoListVC?.sortByPlayCount = byPlayCount
            if self.segmentedControl.selectedSegmentIndex == 0 {
                self.videoListVC?.reloadData()
            }
        }
        headerView.onFollowFailed = { [weak self] message in
            self?.presentAlert(title: "关注操作失败", message: message)
        }
    }

    // MARK: - 资料

    private func loadProfile() {
        guard let mid else { return }
        loadingView.startAnimating()
        Task { [weak self] in
            do {
                async let infoTask = WebRequest.requestUpSpaceInfo(mid: mid)
                async let relationTask = WebRequest.requestUpSpaceRelation(mid: mid)
                let (info, relation) = try await(infoTask, relationTask)
                await MainActor.run {
                    guard let self else { return }
                    self.info = info
                    self.isBlocked = relation.is_blocked
                    self.profileLoaded = true
                    self.loadingView.stopAnimating()
                    self.updateHeader()
                    self.updateBlockedUI()
                    if !self.isBlocked {
                        self.showCurrentTab(forceReload: true)
                    }
                    self.setNeedsFocusUpdate()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.loadingView.stopAnimating()
                    self.presentError(error)
                }
            }
        }
    }

    private func updateHeader() {
        headerView.nameLabel.text = info?.name ?? "-"
        headerView.despLabel.text = info?.sign ?? "-"
        if let avatar = info?.avatar(size: 240) {
            headerView.imageView.kf.setImage(with: avatar, options: .avatar)
        }
        headerView.mid = mid
        headerView.followButton.isOn = info?.is_followed ?? false
        headerView.followButton.isHidden = isBlocked
        headerView.searchButton.isHidden = isBlocked
        headerView.sortButton.isOn = sortByPlayCount
        headerView.sortButton.isHidden = isBlocked || segmentedControl.selectedSegmentIndex == 1
    }

    private func updateBlockedUI() {
        blockedMessageLabel.isHidden = !isBlocked
        contentView.isHidden = isBlocked
        segmentedControl.isHidden = isBlocked
        if isBlocked {
            loadingView.stopAnimating()
        }
    }

    // MARK: - 空间内搜索

    private func presentSpaceSearch() {
        guard let mid else { return }
        let resultVC = SearchResultViewController()
        resultVC.spaceMid = mid
        resultVC.spaceOwnerName = info?.name
        let searchController = UISearchController(searchResultsController: resultVC)
        searchController.searchResultsUpdater = resultVC
        let owner = info?.name ?? ""
        searchController.searchBar.placeholder = owner.isEmpty ? "在该 UP 主的视频中搜索" : "在 \(owner) 的视频中搜索"
        present(UISearchContainerViewController(searchController: searchController), animated: true)
    }

    // MARK: - Tab

    @objc private func segmentChanged(_: UISegmentedControl) {
        showCurrentTab()
    }

    private func showCurrentTab(forceReload: Bool = false) {
        guard profileLoaded, !isBlocked else { return }

        let isSeasons = segmentedControl.selectedSegmentIndex == 1
        let target: any UpSpaceListContent
        var created = false

        if isSeasons {
            if let seasonListVC {
                target = seasonListVC
            } else {
                let vc = UpSpaceSeasonListViewController(mid: mid, ownerName: info?.name ?? "")
                embed(vc)
                seasonListVC = vc
                target = vc
                created = true
            }
        } else {
            if let videoListVC {
                target = videoListVC
            } else {
                let vc = UpSpaceVideoListViewController(mid: mid)
                vc.sortByPlayCount = sortByPlayCount
                embed(vc)
                videoListVC = vc
                target = vc
                created = true
            }
        }

        videoListVC?.view.isHidden = isSeasons
        seasonListVC?.view.isHidden = !isSeasons
        currentListVC = target
        headerView.sortButton.isHidden = isSeasons

        // 新建时 viewDidLoad 里已经发过首次请求，重复 reload 会在切回 Tab 时白跑一轮。
        if forceReload, !created {
            target.reloadData()
        }
        setNeedsFocusUpdate()
    }

    private func embed(_ vc: UIViewController) {
        addChild(vc)
        contentView.addSubview(vc.view)
        vc.view.makeConstraintsToBindToSuperview()
        vc.didMove(toParent: self)
    }

    func reloadData() {
        guard !isBlocked else { return }
        currentListVC?.reloadData()
    }
}

// MARK: - 投稿

final class UpSpaceVideoListViewController: StandardVideoCollectionViewController<ApiRequest.UpSpaceListData>, UpSpaceListContent {
    private let mid: Int
    var sortByPlayCount = false
    private var lastAid: Int?

    var contentCollectionView: UICollectionView { collectionVC.collectionView }

    init(mid: Int) {
        self.mid = mid
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setupCollectionView() {
        super.setupCollectionView()
        collectionVC.pageSize = 20
        collectionVC.loadViewIfNeeded()
        collectionVC.collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 40, right: 0)
    }

    override func request(page: Int) async throws -> [ApiRequest.UpSpaceListData] {
        if page == 1 { lastAid = nil }

        let res = try await ApiRequest.requestUpSpaceVideo(
            mid: mid,
            lastAid: lastAid,
            order: sortByPlayCount ? "click" : "pubdate"
        )
        lastAid = res.last?.aid
        return res
    }
}

// MARK: - 合集

struct UpSpaceSeasonCard: Hashable, DisplayData, PlayableData {
    let meta: UpSpaceSeasonMeta
    let ownerName: String

    var title: String { meta.title }
    var pic: URL? { meta.cover }
    var overlay: DisplayOverlay? {
        DisplayOverlay(
            leftItems: [DisplayOverlay.DisplayOverlayItem(icon: "rectangle.stack", text: "合集")],
            rightItems: [DisplayOverlay.DisplayOverlayItem(icon: nil, text: "\(meta.total) 个视频")]
        )
    }

    // 合集本身不是稿件：基类要求 PlayableData，点选逻辑在 goDetail 里单独接管。
    var aid: Int { 0 }
    var cid: Int { 0 }
}

final class UpSpaceSeasonListViewController: StandardVideoCollectionViewController<UpSpaceSeasonCard>, UpSpaceListContent {
    private let mid: Int
    private let ownerName: String
    private let emptyLabel = UILabel()

    var contentCollectionView: UICollectionView { collectionVC.collectionView }

    init(mid: Int, ownerName: String) {
        self.mid = mid
        self.ownerName = ownerName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setupCollectionView() {
        super.setupCollectionView()
        collectionVC.pageSize = 20
        collectionVC.didLongPress = nil
        collectionVC.loadViewIfNeeded()
        collectionVC.collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 40, right: 0)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // collectionVC.show(in:) 在 super.viewDidLoad 里才把网格加进来，空态要放在它上层。
        setupEmptyLabel()
    }

    private func setupEmptyLabel() {
        view.addSubview(emptyLabel)
        emptyLabel.text = "该 UP 主还没有合集"
        emptyLabel.font = UIFont.systemFont(ofSize: 28, weight: .medium)
        emptyLabel.textColor = UIColor(named: "titleColor") ?? .white
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        emptyLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().offset(40)
            make.trailing.lessThanOrEqualToSuperview().offset(-40)
        }
    }

    override func request(page: Int) async throws -> [UpSpaceSeasonCard] {
        if page == 1 {
            await MainActor.run { emptyLabel.isHidden = true }
        }
        let metas = try await WebRequest.requestUpSpaceSeasons(mid: mid, page: page)
        let cards = metas.map { UpSpaceSeasonCard(meta: $0, ownerName: ownerName) }
        if page == 1 {
            await MainActor.run { emptyLabel.isHidden = !cards.isEmpty }
        }
        return cards
    }

    override func goDetail(with record: UpSpaceSeasonCard) {
        let vc = SeasonArchivesViewController(mid: mid, season: record.meta, ownerName: ownerName)
        present(vc, animated: true)
    }
}
