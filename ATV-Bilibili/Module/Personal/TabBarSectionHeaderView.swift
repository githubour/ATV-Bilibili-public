//
//  TabBarSectionHeaderView.swift
//  ATV-Bilibili
//

import SnapKit
import UIKit

// MARK: - Section Header

class TabBarSectionHeaderView: UICollectionReusableView {
    let label: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 30, weight: .bold)
        l.textColor = .white
        return l
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
        label.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.bottom.equalToSuperview().offset(-4)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
