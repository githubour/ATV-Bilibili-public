//
//  FollowUpAvatarCell.swift
//  ATV-Bilibili
//
//  Created by ATV-Bilibili contributors on 2026/10/11.
//

import Kingfisher
import SnapKit
import UIKit

/// 单个 UP 主头像: 焦点进入时缩放(基类自带倾斜视差) + 白色圆环点亮 + 名字提亮
final class FollowUpAvatarCell: BLMotionCollectionViewCell {
    private let avatarSize: CGFloat = 104
    private let avatarView = UIImageView()
    private let ringView = UIView()
    private let nameLabel = UILabel()

    override func setup() {
        super.setup()
        scaleFactor = 1.16

        ringView.backgroundColor = .white
        ringView.layer.cornerRadius = (avatarSize + 14) / 2
        ringView.alpha = 0
        contentView.addSubview(ringView)

        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = avatarSize / 2
        avatarView.backgroundColor = UIColor(named: "bgColor")
        contentView.addSubview(avatarView)

        nameLabel.font = .systemFont(ofSize: 24, weight: .medium)
        nameLabel.textAlignment = .center
        nameLabel.textColor = .secondaryLabel
        nameLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(nameLabel)

        avatarView.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview().offset(20)
            make.size.equalTo(avatarSize)
        }
        ringView.snp.makeConstraints { make in
            make.center.equalTo(avatarView)
            make.size.equalTo(avatarSize + 14)
        }
        nameLabel.snp.makeConstraints { make in
            make.top.equalTo(avatarView.snp.bottom).offset(14)
            make.leading.trailing.equalToSuperview().inset(8)
        }
    }

    func configure(name: String, face: URL) {
        nameLabel.text = name
        avatarView.kf.setImage(with: face, options: .avatar)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations {
            self.ringView.alpha = self.isFocused ? 1 : 0
            self.nameLabel.textColor = self.isFocused ? .label : .secondaryLabel
        }
    }
}
