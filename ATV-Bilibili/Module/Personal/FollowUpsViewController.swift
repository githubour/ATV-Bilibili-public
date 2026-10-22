//
//  FollowUpsViewController.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/12/6.
//

import Kingfisher
import MarqueeLabel
import SnapKit
import UIKit

class FollowUpsViewController: UIViewController {
    var collectionView: UICollectionView!
    private lazy var emptyLabel = UILabel.emptyState("暂无关注的 UP 主")

    /// 分页状态机收编在 PagedProvider (与关注页头像条同源共用):
    /// 成功才推进页码修掉旧实现的跳页问题, 失败不停摆可滚动重试, 按 mid 去重
    private lazy var provider = PagedProvider<WebRequest.FollowingUser>(
        fetch: { try await WebRequest.requestFollowing(page: $0) },
        dedupKey: { $0.mid }
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        let layout = UICollectionViewCompositionalLayout {
            [weak self] _, _ in
            return self?.makeGridLayoutSection()
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

        collectionView.register(UpCell.self)
        collectionView.dataSource = self
        collectionView.delegate = self
        view.addSubview(collectionView)
        collectionView.makeConstraintsToBindToSuperview()
        view.addSubview(emptyLabel)
        emptyLabel.makeConstraintsCenteredWithinSafeArea(of: view)
        provider.onItemsChange = { [weak self] in
            guard let self else { return }
            self.collectionView.reloadData()
            self.emptyLabel.isHidden = !self.provider.items.isEmpty
        }
        provider.refresh()
    }

    private func makeGridLayoutSection() -> NSCollectionLayoutSection {
        let heightDimension = NSCollectionLayoutDimension.estimated(200)
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(0.33),
            heightDimension: heightDimension
        ))
        item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 30)
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: heightDimension
            ),
            repeatingSubitem: item,
            count: 3
        )
        let vSpacing: CGFloat = 16
        let baseSpacing: CGFloat = 30
        group.edgeSpacing = NSCollectionLayoutEdgeSpacing(leading: .fixed(baseSpacing), top: .fixed(vSpacing), trailing: .fixed(0), bottom: .fixed(vSpacing))
        let section = NSCollectionLayoutSection(group: group)
        if baseSpacing > 0 {
            section.contentInsets = NSDirectionalEdgeInsets(top: baseSpacing, leading: 0, bottom: 0, trailing: 0)
        }

        return section
    }
}

extension FollowUpsViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return provider.items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeue(UpCell.self, for: indexPath)
        let data = provider.items[indexPath.item]
        cell.nameLabel.text = data.uname
        cell.despLabel.text = data.sign
        cell.imageView.kf.setImage(with: data.face, options: .avatar)
        return cell
    }
}

extension FollowUpsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let data = provider.items[indexPath.item]
        let upSpaceVC = UpSpaceViewController()
        upSpaceVC.mid = data.mid
        present(upSpaceVC, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        provider.loadMoreIfNeeded(atIndex: indexPath.row)
    }
}

class UpCell: BLMotionCollectionViewCell {
    let imageView = UIImageView()
    let nameLabel = MarqueeLabel()
    let despLabel = UILabel()

    override func setup() {
        super.setup()
        contentView.addSubview(imageView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(despLabel)
        nameLabel.holdScrolling = true
        imageView.snp.makeConstraints { make in
            make.leading.top.equalToSuperview().offset(30)
            make.bottom.equalToSuperview().offset(-30)
            make.width.equalTo(imageView.snp.height)
            make.width.equalTo(80)
        }

        nameLabel.snp.makeConstraints { make in
            make.leading.equalTo(imageView.snp.trailing).offset(20)
            make.trailing.equalToSuperview().offset(-20)
            make.trailing.equalToSuperview()
            make.top.equalToSuperview().offset(30)
        }

        despLabel.snp.makeConstraints { make in
            make.leading.equalTo(nameLabel.snp.leading)
            make.top.equalTo(nameLabel.snp.bottom).offset(20)
            make.trailing.equalTo(nameLabel.snp.trailing).offset(-20)
        }

        nameLabel.font = UIFont.systemFont(ofSize: 30, weight: .semibold)
        nameLabel.fadeLength = 60
        despLabel.font = UIFont.systemFont(ofSize: 20, weight: .regular)
        despLabel.textColor = UIColor(named: "titleColor")
        contentView.backgroundColor = UIColor(named: "bgColor")
        contentView.layer.cornerRadius = 16
    }

    override var focusMarqueeLabels: [MarqueeLabel] { [nameLabel] }
}

extension WebRequest {
    static func requestFollowing(page: Int) async throws -> [FollowingUser] {
        guard let mid = ApiRequest.getToken()?.mid else { return [] }
        struct Resp: Codable {
            let list: [FollowingUser]
        }

        let list: Resp = try await request(url: EndPoint.followings,
                                           parameters: ["vmid": mid,
                                                        "order_type": "attention",
                                                        "pn": page,
                                                        // PagedProvider 以 40 条/页判断是否到底；不传 ps 时 B 站默认 20，
                                                        // 第一页就会被误判成“最后一页”。显式固定，别依赖服务端默认值。
                                                        "ps": 40])
        return list.list
    }

    struct FollowingUser: Codable {
        let mid: Int
        let uname: String
        let face: URL
        let sign: String
    }
}
