//
//  UIView+Layout.swift
//  ATV-Bilibili
//
//  Created by Etan Chen on 2021/4/4.
//

import SnapKit
import UIKit

extension UIView {
    @discardableResult
    func makeConstraints(_ block: (UIView) -> [NSLayoutConstraint]) -> Self {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(block(self))
        return self
    }

    @discardableResult
    func makeConstraintsToBindToSuperview(_ inset: UIEdgeInsets = .zero) -> Self {
        return makeConstraints { [
            $0.leftAnchor.constraint(equalTo: $0.superview!.leftAnchor, constant: inset.left),
            $0.rightAnchor.constraint(equalTo: $0.superview!.rightAnchor, constant: -inset.right),
            $0.topAnchor.constraint(equalTo: $0.superview!.topAnchor, constant: inset.top),
            $0.bottomAnchor.constraint(equalTo: $0.superview!.bottomAnchor, constant: -inset.bottom),
        ] }
    }

    @discardableResult
    func makeConstraintsBindToCenterOfSuperview() -> Self {
        return makeConstraints { [
            $0.centerXAnchor.constraint(equalTo: $0.superview!.centerXAnchor),
            $0.centerYAnchor.constraint(equalTo: $0.superview!.centerYAnchor),
        ] }
    }
}

// MARK: - 空态提示

extension UILabel {
    /// 无内容时的居中提示文案：默认隐藏，由调用方按加载状态切换
    static func emptyState(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = UIColor.white.withAlphaComponent(0.5)
        label.font = .systemFont(ofSize: 28)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }

    /// 居中于容器，且左右不越出容器的安全区
    func makeConstraintsCenteredWithinSafeArea(of container: UIView) {
        snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualTo(container.safeAreaLayoutGuide).offset(40)
            make.trailing.lessThanOrEqualTo(container.safeAreaLayoutGuide).offset(-40)
        }
    }
}
