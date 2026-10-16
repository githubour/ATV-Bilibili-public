//
//  StandardVideoCollectionViewController.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/11/5.
//

import UIKit

protocol PlayableData: DisplayData {
    var aid: Int { get }
    var cid: Int { get }
}

class StandardVideoCollectionViewController<T: PlayableData>: UIViewController, BLTabBarContentVCProtocol {
    let collectionVC = FeedCollectionViewController()
    var lastReloadDate = Date()
    var reloadInterval: TimeInterval = 60 * 60
    var reloading = false
    private var page = 0
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return [collectionVC.collectionView]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCollectionView()
        collectionVC.show(in: self)
        reloadData()
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        autoReloadIfNeed()
    }

    func setupCollectionView() {
        collectionVC.pageSize = 20
        collectionVC.didSelect = {
            [weak self] item in
            guard let item = item as? T else { return }
            self?.goDetail(with: item)
        }
        collectionVC.loadMore = {
            [weak self] in
            self?.loadMore()
        }
        collectionVC.didLongPress = {
            [weak self] item, index in
            self?.presentSequencePlayMenu(for: item, at: index)
        }
    }

    func supportPullToLoad() -> Bool {
        return true
    }

    func request(page: Int) async throws -> [T] {
        return [T]()
    }

    func goDetail(with record: T) {
        let detailVC = VideoDetailViewController.create(aid: record.aid, cid: record.cid)
        detailVC.present(from: self)
    }

    // MARK: - 长按连续播放

    /// 长按后的菜单：一键三连/稍后再看/我不想看/顺序/倒序播放/隐身播放
    func presentSequencePlayMenu(for item: any DisplayData, at index: Int) {
        let alert = UIAlertController(title: nil, message: item.title, preferredStyle: .alert)
        // 番剧/影视等 PGC 内容 aid 为 0（走另一套「追番」逻辑），只对普通稿件开放这些操作
        if let playable = item as? any PlayableData, playable.aid > 0 {
            alert.addAction(UIAlertAction(title: "一键三连", style: .default) { [weak self] _ in
                Task {
                    let result = await WebRequest.requestOneClickTriple(aid: playable.aid)
                    await MainActor.run {
                        self?.presentAlert(title: "一键三连", message: result)
                    }
                }
            })
            alert.addAction(UIAlertAction(title: "稍后再看", style: .default) { [weak self] _ in
                self?.addToView(aid: playable.aid)
            })
        }
        // 推荐流卡片才提供「不感兴趣」反馈(其他列表不是推荐出来的, 上报无意义)
        if item is ApiRequest.FeedResp.Items {
            alert.addAction(UIAlertAction(title: "我不想看", style: .default) { [weak self] _ in
                self?.presentFeedDislikeMenu(for: item, at: index)
            })
        }
        addSequencePlayActions(to: alert, from: index)
        // 隐身播放同样只对普通稿件开放（PGC 走 epid/seasonId, feed 卡片带不出来）
        if let playable = item as? any PlayableData, playable.aid > 0 {
            alert.addAction(UIAlertAction(title: "隐身播放", style: .default) { [weak self] _ in
                self?.playIncognito(playable)
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    /// 「从此处顺序/倒序播放」动作对: 基类长按菜单与稍后再看页的自定义菜单共用
    func addSequencePlayActions(to alert: UIAlertController, from index: Int) {
        alert.addAction(UIAlertAction(title: "从此处顺序播放", style: .default) { [weak self] _ in
            self?.playSequence(from: index, reversed: false)
        })
        alert.addAction(UIAlertAction(title: "从此处倒序播放", style: .default) { [weak self] _ in
            self?.playSequence(from: index, reversed: true)
        })
    }

    /// 长按菜单「隐身播放」：只播该条且本次播放不写入观看历史（BVideoPlayPlugin 跳过心跳上报）
    private func playIncognito(_ playable: any PlayableData) {
        let player = VideoPlayerViewController(playInfo: PlayInfo(aid: playable.aid,
                                                                  cid: playable.cid,
                                                                  title: playable.title,
                                                                  ownerName: playable.ownerName,
                                                                  coverURL: playable.pic),
                                               isIncognito: true)
        present(player, animated: true)
    }

    // MARK: - 稍后再看

    /// 长按菜单「稍后再看」：调用加入接口，完成后给一个自动消失的轻提示
    func addToView(aid: Int) {
        Task {
            do {
                try await WebRequest.requestToViewAdd(aid: aid)
                Logger.debug("[toview] added aid=\(aid)")
                await MainActor.run { [weak self] in
                    self?.presentToast("已加入稍后再看")
                }
            } catch {
                Logger.warn("[toview] add failed aid=\(aid): \(error)")
                await MainActor.run { [weak self] in
                    self?.presentToast("加入稍后再看失败")
                }
            }
        }
    }

    // MARK: - 推荐流「不感兴趣」

    /// 二级菜单: 选择不感兴趣的原因并上报, 成功后把卡片从当前列表移除
    private func presentFeedDislikeMenu(for item: any DisplayData, at index: Int) {
        let alert = UIAlertController(title: "不感兴趣", message: "将减少此类内容推荐:\n\(item.title)", preferredStyle: .alert)
        guard let playable = item as? any PlayableData else { return }
        alert.addAction(UIAlertAction(title: "不感兴趣：当前视频", style: .default) { [weak self] _ in
            self?.feedDislike(aid: playable.aid, reason: .currentVideo, at: index)
        })
        alert.addAction(UIAlertAction(title: "不感兴趣：up", style: .default) { [weak self] _ in
            self?.feedDislike(aid: playable.aid, reason: .upOwner, at: index)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func feedDislike(aid: Int, reason: ApiRequest.FeedDislikeReason, at index: Int) {
        Task {
            do {
                try await ApiRequest.requestFeedDislike(aid: aid, reason: reason)
                await MainActor.run {
                    // 上报成功: 卡片从当前流移除(服务端同时减少同类推荐)
                    let items = collectionVC.displayDatas
                    guard items.indices.contains(index) else { return }
                    var remaining = items
                    remaining.remove(at: index)
                    collectionVC.displayDatas = remaining
                }
                Logger.debug("[feed-dislike] reported aid=\(aid) reason=\(reason.rawValue)")
            } catch {
                Logger.warn("[feed-dislike] report failed aid=\(aid): \(error)")
            }
        }
    }

    func playSequence(from index: Int, reversed: Bool) {
        let items = collectionVC.displayDatas
        guard items.indices.contains(index) else { return }

        let seq = items.compactMap { item -> PlayInfo? in
            guard let playable = item as? any PlayableData else { return nil }
            return PlayInfo(aid: playable.aid,
                            cid: playable.cid,
                            title: item.title,
                            ownerName: item.ownerName,
                            coverURL: item.pic)
        }
        // 列表中可能存在非 PlayableData 的项，下标要按实际入列的数量换算
        let startIndex = items[0..<index].compactMap { $0 as? any PlayableData }.count
        guard seq.indices.contains(startIndex) else { return }

        Logger.info("[sequence] \(reversed ? "倒序" : "顺序")播放，起点 \(startIndex + 1)/\(seq.count)")
        let player = VideoPlayerViewController(playInfo: seq[startIndex])
        player.sequenceProvider = VideoSequenceProvider(seq: seq, currentIndex: startIndex)
        player.sequencePlayDirection = reversed ? .reverse : .forward
        present(player, animated: true)
    }

    func reloadData() {
        Task {
            await reallyReloadData()
        }
    }

    func reallyReloadData() async {
        if reloading { return }
        reloading = true
        defer {
            reloading = false
        }
        lastReloadDate = Date()
        page = 1
        do {
            let res = try await request(page: 1)
            collectionVC.displayDatas = []
            collectionVC.appendData(displayData: res)
        } catch let err {
            presentError(err)
        }
    }

    // MARK: - Private

    private func loadMore() {
        guard supportPullToLoad() else { return }
        Task {
            do {
                let res = try await request(page: page + 1)
                collectionVC.appendData(displayData: res)
                page += 1
            } catch {
                // 翻页是自动触发的，失败只记日志不弹窗，避免打断浏览
                Logger.warn(error)
            }
        }
    }

    func autoReloadIfNeed() {
        guard isViewLoaded, view.window != nil else { return }
        guard Date().timeIntervalSince(lastReloadDate) > reloadInterval else { return }
        Task {
            await reallyReloadData()
        }
    }

    @objc private func didBecomeActive() {
        autoReloadIfNeed()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
