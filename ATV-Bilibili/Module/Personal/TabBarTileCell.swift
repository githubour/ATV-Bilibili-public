//
//  TabBarTileCell.swift
//  ATV-Bilibili
//

import SnapKit
import UIKit

// MARK: - Tile Cell

class TabBarTileCell: BLMotionCollectionViewCell {
    private var isBeingEdited = false
    private let capsuleBackground = BLCapsuleBackgroundView()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 28, weight: .medium)
        l.textAlignment = .center
        l.numberOfLines = 2
        l.adjustsFontSizeToFitWidth = true
        l.minimumScaleFactor = 0.7
        return l
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, isBeingEdited: Bool) {
        titleLabel.text = title
        self.isBeingEdited = isBeingEdited
        setShaking(isBeingEdited)
        updateAppearance()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.layer.removeAnimation(forKey: "shake")
        transform = .identity
        isBeingEdited = false
    }

    // MARK: - Private

    private func setShaking(_ shaking: Bool) {
        if shaking {
            guard contentView.layer.animation(forKey: "shake") == nil else { return }
            let anim = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            anim.values = [-0.015, 0.015, -0.015]
            anim.duration = 0.22
            anim.repeatCount = .infinity
            contentView.layer.add(anim, forKey: "shake")
        } else {
            contentView.layer.removeAnimation(forKey: "shake")
        }
    }

    private func setupView() {
        contentView.addSubview(capsuleBackground)
        capsuleBackground.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        capsuleBackground.clipsToBounds = true

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 8)
        layer.shadowRadius = 12
        layer.shadowOpacity = 0

        contentView.addSubview(titleLabel)

        titleLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().offset(24)
            make.trailing.lessThanOrEqualToSuperview().offset(-24)
        }
        updateAppearance()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations {
            self.updateAppearance()
        }
    }

    private func updateAppearance() {
        if isFocused {
            capsuleBackground.backgroundColor = .white
            titleLabel.textColor = .black
            layer.shadowOpacity = 0.3
        } else {
            capsuleBackground.backgroundColor = UIColor(white: 0.15, alpha: 1)
            titleLabel.textColor = .white
            layer.shadowOpacity = 0
        }
    }
}
