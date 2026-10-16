//
//  SettingsHeaderView.swift
//  ATV-Bilibili
//

import SnapKit
import UIKit

class SettingsHeaderView: UICollectionReusableView {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setup() {
        addSubview(label)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = UIColor.secondaryLabel
        label.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(20)
            make.top.equalToSuperview().offset(20)
            make.bottom.equalToSuperview().offset(-20)
        }
    }
}
