//
//  RelatedVideoCell.swift
//  ATV-Bilibili
//

import Kingfisher
import MarqueeLabel
import SnapKit
import UIKit

class RelatedVideoCell: BLMotionCollectionViewCell {
    let titleLabel = MarqueeLabel()
    let imageView = BLRoundedImageView()
    override func setup() {
        super.setup()
        contentView.addSubview(imageView)
        contentView.addSubview(titleLabel)
        imageView.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
            make.width.equalTo(imageView.snp.height).multipliedBy(14.0 / 9)
        }
        imageView.contentMode = .scaleAspectFill
        titleLabel.snp.makeConstraints { make in
            make.left.right.bottom.equalToSuperview()
            make.top.equalTo(imageView.snp.bottom).offset(6)
        }
        titleLabel.setContentHuggingPriority(.required, for: .vertical)
        titleLabel.font = UIFont.systemFont(ofSize: 28)
        titleLabel.fadeLength = 60
        suspendFocusMarquee()
    }

    func update(data: any DisplayData) {
        titleLabel.text = data.title
        imageView.kf.setImage(with: data.pic, options: .cover(width: 360, height: 202))
    }

    override var focusMarqueeLabels: [MarqueeLabel] { [titleLabel] }

    override func prepareForReuse() {
        super.prepareForReuse()
        suspendFocusMarquee()
    }
}
