//
//  UpSpaceProfileHeaderView.swift
//  ATV-Bilibili
//
//  Created by bitxeno on 2025/11/27.
//

import SnapKit
import UIKit

/// UP 空间顶部资料卡。空间页改成固定头 + 投稿/合集切换后，它作为普通视图使用。
class UpSpaceProfileHeaderView: UIView {
    let imageView = UIImageView()
    let nameLabel = UILabel()
    let despLabel = UILabel()
    let followButton = BLCustomButton()
    let searchButton = BLCustomButton()
    let sortButton = BLCustomButton()
    private let focusGuide = UIFocusGuide()

    var onFollowTapped: ((Bool) -> Void)?
    /// 关注请求失败时回调；调用方负责展示提示
    var onFollowFailed: ((String) -> Void)?
    var onSearchTapped: (() -> Void)?
    var onSortTapped: ((Bool) -> Void)?
    var mid: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    private func setupUI() {
        addSubview(imageView)
        addSubview(nameLabel)
        addSubview(despLabel)
        addSubview(followButton)
        addSubview(searchButton)
        addSubview(sortButton)
        addLayoutGuide(focusGuide)

        imageView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(30)
            make.top.equalToSuperview()
            make.width.height.equalTo(110)
        }

        nameLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(5)
            make.leading.equalTo(imageView.snp.trailing).offset(20)
        }

        despLabel.snp.makeConstraints { make in
            make.leading.equalTo(nameLabel.snp.leading)
            make.top.equalTo(nameLabel.snp.bottom).offset(20)
            make.trailing.lessThanOrEqualTo(sortButton.snp.leading).offset(-40)
        }

        searchButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-30)
            make.centerY.equalToSuperview()
            make.width.equalTo(searchButton.snp.height).multipliedBy(20.5 / 18.0)
            make.height.equalTo(80)
        }

        followButton.snp.makeConstraints { make in
            make.trailing.equalTo(searchButton.snp.leading).offset(-20)
            make.centerY.equalToSuperview()
            make.width.equalTo(followButton.snp.height).multipliedBy(20.5 / 18.0)
            make.height.equalTo(80)
        }

        sortButton.snp.makeConstraints { make in
            make.trailing.equalTo(followButton.snp.leading).offset(-20)
            make.centerY.equalToSuperview()
            make.width.equalTo(sortButton.snp.height).multipliedBy(20.5 / 18.0)
            make.height.equalTo(80)
        }

        nameLabel.font = UIFont.systemFont(ofSize: 30, weight: .semibold)
        despLabel.font = UIFont.systemFont(ofSize: 23, weight: .regular)
        despLabel.textColor = UIColor(named: "titleColor")
        despLabel.numberOfLines = 2

        followButton.image = UIImage(systemName: "heart")
        followButton.onImage = UIImage(systemName: "heart.fill")
        followButton.accessibilityLabel = "关注 UP 主"
        searchButton.accessibilityLabel = "搜索该 UP 主"
        sortButton.accessibilityLabel = "切换投稿排序方式"
        followButton.onPrimaryAction = { [weak self] _ in
            self?.followButtonTapped()
        }

        searchButton.image = UIImage(systemName: "magnifyingglass")
        searchButton.onPrimaryAction = { [weak self] _ in
            self?.onSearchTapped?()
        }

        // isOn = 按播放量排序，off = 按最新发布
        sortButton.image = UIImage(systemName: "clock")
        sortButton.onImage = UIImage(systemName: "flame.fill")
        sortButton.onPrimaryAction = { [weak self] _ in
            self?.sortButtonTapped()
        }

        focusGuide.preferredFocusEnvironments = [sortButton, followButton, searchButton]
        focusGuide.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.top.bottom.equalTo(sortButton)
            make.trailing.equalTo(sortButton.snp.leading)
        }
    }

    @objc private func sortButtonTapped() {
        sortButton.isOn.toggle()
        onSortTapped?(sortButton.isOn)
    }

    @objc private func followButtonTapped() {
        followButton.isOn.toggle()
        onFollowTapped?(followButton.isOn)

        guard let mid else { return }
        let follow = followButton.isOn
        Task { @MainActor [weak self] in
            do {
                try await WebRequest.follow(mid: mid, follow: follow)
            } catch {
                // 与详情页/播放器面板一致：失败回滚状态并提示，不能静默显示“已关注”
                self?.followButton.isOn = !follow
                self?.onFollowFailed?(error.localizedDescription)
            }
        }
    }
}
