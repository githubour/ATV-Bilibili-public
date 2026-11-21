//
//  VideoDetailViewController+Collections.swift
//  ATV-Bilibili
//
//  从 VideoDetailViewController.swift 迁出的集合视图代理/数据源/布局（审核行动项 #9），零行为变化。
//

import UIKit

extension VideoDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        // 兜底：tvOS 26+ 对"完全展开的嵌套集合视图"的焦点跟随不完全可靠，
        // 焦点落进评论卡后显式把卡片滚进外层 scrollView 可视区（已在可视区内时是 no-op）
        guard collectionView === replysCollectionView,
              let cell = context.nextFocusedView as? UICollectionViewCell,
              cell.isDescendant(of: collectionView) else { return }
        let frame = collectionView.convert(cell.frame, to: scrollView)
        scrollView.scrollRectToVisible(frame.insetBy(dx: 0, dy: -60), animated: true)
    }

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
            if indexPath.item < displayedReplies.count {
                let detail = ReplyDetailViewController(reply: displayedReplies[indexPath.item])
                present(detail, animated: true)
            } else {
                (collectionView.cellForItem(at: indexPath) as? ReplyLoadMoreCell)?.setLoading(true)
                loadMoreReplies()
            }
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
            return displayedReplies.count + (hasMoreReplies ? 1 : 0)
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
            if indexPath.item < displayedReplies.count {
                let cell = collectionView.dequeue(ReplyCell.self, for: indexPath)
                cell.maxContentLines = 3
                cell.config(replay: displayedReplies[indexPath.item])
                return cell
            }
            let cell = collectionView.dequeue(ReplyLoadMoreCell.self, for: indexPath)
            cell.setLoading(isRepliesLoading)
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
