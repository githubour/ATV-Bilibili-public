//
//  ReplyLoadMoreCell.swift
//  ATV-Bilibili
//
//  评论格末尾的「加载更多」卡：和评论卡同一套玻璃底材，选中后拉取下一页最新评论
//

import SnapKit
import UIKit

final class ReplyLoadMoreCell: BLMotionCollectionViewCell {
    private let containerView = UIVisualEffectView(effect: BLGlass.effect())
    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    override func setup() {
        super.setup()
        scaleFactor = 1.03
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        containerView.clipsToBounds = true
        containerView.layer.cornerCurve = .continuous
        contentView.addSubview(containerView)
        containerView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        iconView.tintColor = .label
        iconView.contentMode = .scaleAspectFit

        titleLabel.font = .systemFont(ofSize: 26, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        containerView.contentView.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().offset(20)
            make.trailing.lessThanOrEqualToSuperview().offset(-20)
        }
        iconView.snp.makeConstraints { make in
            make.size.equalTo(46)
        }
        setLoading(false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        containerView.layer.cornerRadius = BLCardCornerRadius.value(forHeight: containerView.bounds.height)
    }

    func setLoading(_ loading: Bool) {
        titleLabel.text = loading ? "正在加载…" : "加载更多评论"
        iconView.image = UIImage(systemName: loading ? "hourglass" : "arrow.down.circle")
        accessibilityLabel = titleLabel.text
    }
}
