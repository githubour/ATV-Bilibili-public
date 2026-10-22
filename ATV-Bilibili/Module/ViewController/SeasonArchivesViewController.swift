//
//  SeasonArchivesViewController.swift
//  ATV-Bilibili
//
//  UP 空间「合集」内视频清单。
//

import UIKit

struct SeasonArchiveCard: Hashable, DisplayData, PlayableData {
    let archive: SeasonArchive
    let ownerName: String

    var title: String { archive.title }
    var pic: URL? { archive.pic }
    var date: String? { DateFormatter.stringFor(timestamp: archive.pubdate) }
    var overlay: DisplayOverlay? {
        .video(
            play: archive.stat?.view,
            danmaku: archive.stat?.danmaku,
            durationText: archive.duration.map { TimeInterval($0).timeString() }
        )
    }

    var aid: Int { archive.aid }
    // 合集接口不返回 cid；沿用 UP 空间列表的约定，进详情页后再解析。
    var cid: Int { 0 }
}

final class SeasonArchivesViewController: StandardVideoCollectionViewController<SeasonArchiveCard> {
    private let mid: Int
    private let season: UpSpaceSeasonMeta
    private let ownerName: String

    init(mid: Int, season: UpSpaceSeasonMeta, ownerName: String) {
        self.mid = mid
        self.season = season
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
        collectionVC.showHeader = true
        collectionVC.headerText = "\(season.title) · 共 \(season.total) 个视频"
        collectionVC.loadViewIfNeeded()
        collectionVC.collectionView.contentInset = UIEdgeInsets(top: 20, left: 0, bottom: 40, right: 0)
    }

    override func request(page: Int) async throws -> [SeasonArchiveCard] {
        let archives = try await WebRequest.requestUpSpaceSeasonArchives(
            mid: mid,
            seasonId: season.season_id,
            page: page
        )
        return archives.map { SeasonArchiveCard(archive: $0, ownerName: ownerName) }
    }

    override func goDetail(with record: SeasonArchiveCard) {
        let detailVC = VideoDetailViewController.create(aid: record.aid, cid: nil)
        // 合集内容固定先进详情页：详情页会识别 ugc_season，并按现有合集/分节规则建立连播队列。
        // 直进播放只带单集信息，会丢掉合集连播与选集栏。
        detailVC.present(from: self, directlyEnterVideo: false)
    }
}
