//
//  EpisodeCardCell.swift
//  ATV-Bilibili
//
//  播放器中选集栏的分集卡片：16:9 封面 + 左上角集数徽标 + 单行标题。
//  焦点缩放与视差由 BLMotionCollectionViewCell 基类统一提供。
//

import Kingfisher
import MarqueeLabel
import SnapKit
import UIKit

final class EpisodeCardCell: BLMotionCollectionViewCell {
    static let reuseIdentifier = String(describing: EpisodeCardCell.self)
    /// 非当前集只做轻微降权：信息面板铺在深色材质上，压太暗会显得整排发灰
    private static let inactiveAlpha: CGFloat = 0.8

    private let imageView = BLRoundedImageView()
    private let indexLabel = UILabel()
    private let titleLabel = MarqueeLabel()

    /// 当前正在播放的一集：封面加白色描边 + 不透明；其余半透明降权
    var isCurrent = false {
        didSet { applyCurrentState() }
    }

    override func setup() {
        super.setup()
        scaleFactor = 1.08

        imageView.contentMode = .scaleAspectFill
        contentView.addSubview(imageView)

        indexLabel.font = UIFont.systemFont(ofSize: 22, weight: .semibold)
        indexLabel.textColor = .white
        indexLabel.textAlignment = .center
        indexLabel.backgroundColor = UIColor(white: 0, alpha: 0.55)
        indexLabel.layer.cornerRadius = 8
        indexLabel.clipsToBounds = true
        contentView.addSubview(indexLabel)

        titleLabel.font = UIFont.systemFont(ofSize: 26)
        titleLabel.textColor = .white
        titleLabel.fadeLength = 40
        titleLabel.holdScrolling = true
        contentView.addSubview(titleLabel)

        imageView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(imageView.snp.width).multipliedBy(9.0 / 14.0)
        }
        indexLabel.snp.makeConstraints { make in
            make.top.leading.equalTo(imageView).offset(10)
            make.height.equalTo(36)
            make.width.greaterThanOrEqualTo(44)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.top.equalTo(imageView.snp.bottom).offset(8)
        }
        titleLabel.setContentHuggingPriority(.required, for: .vertical)

        contentView.layer.cornerCurve = .continuous
        applyCurrentState()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 「当前集」的白色描边要贴合封面圆角, 与封面共用同一套按高度取值的规则
        contentView.layer.cornerRadius = BLCardCornerRadius.value(forHeight: contentView.bounds.height)
    }

    func update(with entry: EpisodeEntry) {
        titleLabel.text = entry.title
        indexLabel.text = entry.indexText
        imageView.kf.setImage(with: entry.coverURL, options: .cover(width: 320, height: 180))
    }

    private func applyCurrentState() {
        contentView.alpha = isCurrent ? 1 : Self.inactiveAlpha
        imageView.alpha = 1
        titleLabel.textColor = isCurrent ? .bilibiliPink : .white
        updateCoverRing()
    }

    /// 白色描边只圈封面：圈到整块 contentView 会把下面的标题一起框进去
    private func updateCoverRing() {
        let showsRing = isFocused || isCurrent
        imageView.layer.borderWidth = showsRing ? 4 : 0
        imageView.layer.borderColor = showsRing ? UIColor.white.cgColor : nil
    }

    override var focusMarqueeLabels: [MarqueeLabel] { [titleLabel] }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations {
            self.titleLabel.textColor = self.isFocused ? .white : (self.isCurrent ? .bilibiliPink : .white)
            self.contentView.alpha = (self.isFocused || self.isCurrent) ? 1 : Self.inactiveAlpha
        }
        updateCoverRing()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isCurrent = false
        imageView.kf.cancelDownloadTask()
        imageView.image = nil
        suspendFocusMarquee()
    }
}
