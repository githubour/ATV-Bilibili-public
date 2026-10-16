//
//  ToViewViewController.swift
//  ATV-Bilibili
//
//  Created by Etan Chen on 2021/4/5.
//

import Alamofire
import UIKit

class ToViewViewController: StandardVideoCollectionViewController<ToViewData> {
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
        guard let csrf = CookieHandler.shared.csrf() else { return }
        AF.request(WebRequest.EndPoint.toViewDel, method: .post, parameters: ["aid": aid, "csrf": csrf]).responseData {
            [weak self] resp in
            Logger.debug("[toview] del result: \(resp.result)")
            self?.reloadData()
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
    let stat: Stat?

    var durationString: String {
        TimeInterval(duration).timeString()
    }

    struct Stat: Codable, Hashable {
        let view: Int
        let danmaku: Int
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
}
