//
//  ToViewViewController.swift
//  ATV-Bilibili
//
//  Created by Etan Chen on 2021/4/5.
//

import SnapKit
import UIKit

class ToViewViewController: StandardVideoCollectionViewController<ToViewData> {
    /// 批量移除「即将播完」的条目；destructive 操作，先弹确认框。
    /// 注意不能直接把 viewed=true 交给服务端：那样只要播过几秒就算「已观看」，会误删。
    private lazy var removeWatchedButton: BLCustomTextButton = {
        let button = BLCustomTextButton()
        button.title = "移除已播放"
        button.titleFont = .systemFont(ofSize: 30, weight: .semibold)
        button.titleColor = .white
        button.backgroundEffect = BLGlass.effect()
        return button
    }()

    /// 顶行任意列卡片上滑 → 引导到右上角按钮（单视频时按钮与卡片水平投影无重叠）
    private let topFocusGuide = UIFocusGuide()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(removeWatchedButton)
        removeWatchedButton.onPrimaryAction = { [weak self] _ in
            self?.confirmRemoveWatched()
        }
        removeWatchedButton.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(4)
            make.trailing.equalToSuperview().offset(-80)
            make.height.equalTo(72)
        }
        // 列表整体下移到按钮之下，避免顶行卡片与按钮重叠。
        // show(in:) 装的是原生 NSLayoutConstraint（非 SnapKit），remakeConstraints 清不掉，
        // 只能手动停掉 4 边约束里的 top 再补新的（同 VideoDetailViewController 的 storyboard 约束改法）
        view.constraints
            .filter { ($0.firstItem as? UIView) === collectionVC.view && $0.firstAttribute == .top }
            .forEach { $0.isActive = false }
        collectionVC.view.snp.makeConstraints { make in
            make.top.equalTo(removeWatchedButton.snp.bottom).offset(8)
        }

        view.addLayoutGuide(topFocusGuide)
        topFocusGuide.snp.makeConstraints { make in
            make.leading.trailing.equalTo(collectionVC.view)
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.bottom.equalTo(collectionVC.view.snp.top)
        }
        topFocusGuide.preferredFocusEnvironments = [removeWatchedButton]

        updateRemoveEntry()
    }

    /// 列表为空时按钮无事可做：隐藏并停用顶部焦点引导。
    /// 否则空列表下焦点会落到这个右上角按钮上——它在这里既没有下方卡片、左侧又是头像区，
    /// 焦点进来就出不去了，左侧子 Tab 栏（收藏/追番/关注UP/历史记录）也换不过去。
    private func updateRemoveEntry() {
        let isEmpty = collectionVC.displayDatas.isEmpty
        let wasFocused = removeWatchedButton.isFocused
        removeWatchedButton.isHidden = isEmpty
        topFocusGuide.isEnabled = !isEmpty
        // 清空列表时焦点原本就停在这个按钮上，隐藏后要主动交还给上层（左侧子 Tab 栏）
        if isEmpty, wasFocused {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    /// 空列表时内容区没有可聚焦项，别把焦点交给空的 collectionView，交给上层决定
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        collectionVC.displayDatas.isEmpty ? [] : super.preferredFocusEnvironments
    }

    override func reallyReloadData() async {
        await super.reallyReloadData()
        updateRemoveEntry()
    }

    private func confirmRemoveWatched() {
        let alert = UIAlertController(title: "移除已播放",
                                      message: "只移除已经看到 95% 以上（即将播完）的视频，看了一部分的会保留",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "移除", style: .destructive) { [weak self] _ in
            self?.removeWatched()
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel Action"), style: .cancel))
        present(alert, animated: true)
    }

    private func removeWatched() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let count = try await WebRequest.requestToViewRemoveNearlyFinished()
                self.presentToast(count > 0 ? "已移除 \(count) 个即将播完的视频" : "没有即将播完的视频")
            } catch {
                self.presentError(error, title: "移除失败")
            }
            // 中途失败也已删掉一部分，统一刷一次让列表回到真实状态
            self.reloadData()
        }
    }

    override func setupCollectionView() {
        super.setupCollectionView()
        collectionVC.didSelect = { [weak self] record in
            guard let self,
                  let record = record as? ToViewData
            else { return }
            goDetail(with: record)
        }
        // 覆写基类的长按菜单：删除之外还要保留连续播放，否则会被整体覆盖掉
        collectionVC.didLongPress = {
            [weak self] record, index in
            guard let self,
                  let record = record as? ToViewData
            else { return }
            let alert = UIAlertController(title: nil, message: record.title, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("Delete", comment: "Delete Action"), style: .destructive) { [weak self] _ in
                self?.del(with: record)
            })
            addSequencePlayActions(to: alert, from: index)
            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel Action"), style: .cancel))
            self.present(alert, animated: true)
        }
    }

    override func supportPullToLoad() -> Bool {
        return false
    }

    override func goDetail(with feed: ToViewData) {
        let vc = VideoDetailViewController.create(aid: feed.aid, cid: feed.cid)
        vc.present(from: self)
    }

    func del(with toViewItem: ToViewData) {
        let aid = toViewItem.aid
        Task { [weak self] in
            guard let self else { return }
            do {
                try await WebRequest.requestToViewDel(aid: aid)
                self.reloadData()
            } catch {
                self.presentError(error, title: "删除失败")
            }
        }
    }

    override func request(page: Int) async throws -> [ToViewData] {
        return try await WebRequest.requestToView()
    }
}

struct ToViewData: PlayableData, Codable {
    let title: String
    let cid: Int
    let aid: Int
    let owner: VideoOwner
    let pic: URL?
    let pubdate: Int
    let duration: Int
    /// 观看进度（秒）。接口用 -1 表示已看完，0/缺省表示还没开始看
    let progress: Int?
    /// 分 P 信息。多 P 稿件里 cid 指向正在看的那一 P，而 duration 是所有 P 的总时长
    let pages: [Page]?
    let stat: Stat?

    var durationString: String {
        TimeInterval(duration).timeString()
    }

    struct Stat: Codable, Hashable {
        let view: Int
        let danmaku: Int
    }

    struct Page: Codable, Hashable {
        let cid: Int?
        let duration: Int?
    }

    /// 进度对应的时长：多 P 稿件按当前这一 P 算，缺 pages 时退回全片总时长
    private var progressDuration: Int {
        if let page = pages?.first(where: { $0.cid == cid }), let pageDuration = page.duration, pageDuration > 0 {
            return pageDuration
        }
        return duration
    }

    /// 即将播完：服务端标记已看完（progress = -1），或已看至 95% 以上。
    /// 只播了一点点的条目必须保留——服务端 viewed=true 的判定宽得多，那是「播过」不是「播完」。
    var isNearlyFinished: Bool {
        guard let progress else { return false }
        if progress < 0 { return true }
        let total = progressDuration
        guard progress > 0, total > 0 else { return false }
        return Double(progress) >= Double(total) * 0.95
    }

    var ownerName: String {
        return owner.name
    }

    var avatar: URL? { owner.face.flatMap(URL.init(string:)) }

    var date: String? {
        return DateFormatter.stringFor(timestamp: pubdate)
    }

    var overlay: DisplayOverlay? {
        .video(play: stat?.view, danmaku: stat?.danmaku, durationText: durationString)
    }
}

extension WebRequest {
    static func requestToView() async throws -> [ToViewData] {
        struct Resp: Codable {
            var list: [ToViewData]?
        }
        let res: Resp = try await request(url: EndPoint.toViewList)
        return res.list ?? []
    }

    /// 加入稍后再看。幂等：已存在于列表中时服务端同样返回 code 0
    static func requestToViewAdd(aid: Int) async throws {
        try await requestVoid(method: .post, url: EndPoint.toViewAdd, parameters: ["aid": aid])
    }

    /// 删除稍后再看。走统一请求层，失败抛错由页面提示，不再静默刷新。
    static func requestToViewDel(aid: Int) async throws {
        guard let csrf = CookieHandler.shared.csrf() else {
            throw RequestError.statusFail(code: -1, message: "登录状态异常，请重新扫码登录")
        }
        try await requestVoid(method: .post,
                              url: EndPoint.toViewDel,
                              parameters: ["aid": aid, "csrf": csrf])
    }

    /// 清理稍后再看里「即将播完」的条目，返回删掉的条数。
    /// 不能用 del 的 viewed=true：那个口径是「播过」，刚看几秒的也会一起删；
    /// 这里拉一次列表按进度自己筛，再逐条删（del 一次只收一个 aid，没有批量参数）。
    /// 番剧/影视条目 aid 为 0，按 aid 删不掉，跳过。
    static func requestToViewRemoveNearlyFinished() async throws -> Int {
        let targets = try await requestToView().filter { $0.aid > 0 && $0.isNearlyFinished }
        for target in targets {
            try await requestToViewDel(aid: target.aid)
        }
        return targets.count
    }

    /// 当前 aid 是否已在稍后再看列表中（详情页按钮状态回填；查询失败按不在列表处理）
    static func requestIsInToView(aid: Int) async -> Bool {
        let list = (try? await requestToView()) ?? []
        return list.contains { $0.aid == aid }
    }
}
