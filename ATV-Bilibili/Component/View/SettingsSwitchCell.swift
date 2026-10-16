//
//  SettingsSwitchCell.swift
//  ATV-Bilibili
//

import SnapKit
import UIKit

class SettingsSwitchCell: BLMotionCollectionViewCell {
    private let titleLabel = UILabel()
    private let descLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(with model: SettingsViewController.CellModel) {
        titleLabel.text = model.title
        descLabel.text = model.desp()
        model.updateAction = { [weak self] in
            self?.descLabel.text = model.desp()
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        updateColor()
    }

    func setupView() {
        contentView.addSubview(titleLabel)
        contentView.addSubview(descLabel)
        contentView.layer.cornerRadius = 10

        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(20)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(descLabel.snp.leading).offset(-10)
        }

        descLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-20)
            make.centerY.equalToSuperview()
        }

        descLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        updateColor()
    }

    func updateColor() {
        if traitCollection.userInterfaceStyle == .dark {
            if isFocused {
                contentView.backgroundColor = UIColor.white
                titleLabel.textColor = UIColor.black
                descLabel.textColor = UIColor.black
            } else {
                contentView.backgroundColor = UIColor.clear
                titleLabel.textColor = UIColor.white
                descLabel.textColor = UIColor.secondaryLabel
            }
        } else {
            contentView.backgroundColor = isFocused ? UIColor.white : UIColor.clear
            titleLabel.textColor = .black
            descLabel.textColor = UIColor.secondaryLabel
        }
    }
}
