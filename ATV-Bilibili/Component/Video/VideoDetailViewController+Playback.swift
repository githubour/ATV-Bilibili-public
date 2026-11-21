//
//  VideoDetailViewController+Playback.swift
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

// 起播与分 P 播放序列

extension VideoDetailViewController {
    /// 详情页起播/分 P：把已取到的 detail/playerInfo 传给播放器；只在同一 aid/cid 时复用，避免串集。
    func makeVideoPlayer(for playInfo: PlayInfo) -> VideoPlayerViewController {
        let canSeed = playInfo.aid == aid && (playInfo.cid ?? 0) == cid
        let player = VideoPlayerViewController(playInfo: playInfo,
                                               initialDetail: data,
                                               initialPlayerInfo: canSeed ? detailPlayerInfo : nil)
        // 播放器内切集/连播只更新播放器自己的 sequenceProvider；退出时把最后的实际集号与进度回写到详情页，
        // 否则详情页会停在起播那一集，「继续播放」也指回旧集。
        player.onDismissPlayback = { [weak self] info, playTime in
            self?.applyPlayerEpisode(info, playTime: playTime)
        }
        return player
    }

    /// 把播放器退出时的实际集号/进度回写到详情页；只改本地状态，不触发内容重载。
    private func applyPlayerEpisode(_ info: PlayInfo, playTime: Int?) {
        guard let newCid = info.cid, newCid > 0 else { return }
        // 只回写当前详情页选集内的条目；播放器临时切到别的稿件时（相关推荐等）保持详情页不变。
        guard pages.contains(where: { $0.cid == newCid }) else { return }
        let episodeChanged = newCid != cid
        cid = newCid
        if episodeChanged {
            // 缓存的 playerInfo 属于旧 cid，留着会被当成新一集的续播/字幕数据，清掉让播放器按新 cid 重新取
            detailPlayerInfo = nil
        }
        if let newEpid = info.epid, newEpid > 0 {
            epid = newEpid
        }
        if isBangumi, let page = pages.first(where: { $0.cid == newCid }) {
            aid = page.page
        }
        lastPlayCid = newCid
        if let playTime, playTime > 0 {
            playTimeInSecond = playTime
        } else if episodeChanged {
            playTimeInSecond = 0
        }
        updatePlayButtonTitle()
        scrollPageCollectionToCurrentPage()
    }

    /// 让详情页选集条定位到当前集；只滚动，不 reload、不请求。
    private func scrollPageCollectionToCurrentPage() {
        guard pages.count > 1, let index = pages.firstIndex(where: { $0.cid == cid }) else { return }
        pageCollectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .left, animated: false)
    }

    /// 起播的单一构造入口：「播放」按钮与直进播放两条路径共用，避免 PlayInfo 参数漂移。
    /// 带 subType/title，并按多 P / 合集挂连播序列——选集面板依赖 provider.count > 1（VideoPlayerViewModel），不挂就没有。
    private func presentVideoPlayer() {
        let player = makeVideoPlayer(for: PlayInfo(aid: aid, cid: cid, epid: epid, seasonId: seasonId, subType: subType, lastPlayCid: lastPlayCid, playTimeInSecond: playTimeInSecond, title: data?.title))
        if pages.count > 0, let index = pages.firstIndex(where: { $0.cid == cid }) {
            // 番剧每集 aid 不同（VideoPage.page 即该集 aid）；多 P 视频的 page 是分 P 序号，aid 不变
            let seq = pages.map({ PlayInfo(aid: isBangumi ? $0.page : aid, cid: $0.cid, epid: $0.epid, seasonId: seasonId, subType: subType, title: $0.part) })
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

    @IBAction func actionPlay(_ sender: Any) {
        // 用户已经手动起播：取消「解析完成后自动直进」，避免再叠一个播放器
        pendingDirectEntry = false
        presentVideoPlayer()
    }

    /// 直进起播：aid/cid 已确定后直接开播放器（深链/续看横幅带入 cid，或解析完成后的补起播）。
    func enterVideoDirectly() {
        presentVideoPlayer()
    }
}
