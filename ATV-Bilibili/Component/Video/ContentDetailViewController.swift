//
//  ContentDetailViewController.swift
//  ATV-Bilibili
//

import SnapKit
import UIKit

/// 视频简介：卡片式浮层，不是全屏铺满。
/// 背景保持足够不透明，避免详情页封面/文字透上来影响阅读；进出用短促的弹簧缩放 + 背景渐隐。
class ContentDetailViewController: UIViewController {
    private let titleLabel = UILabel()
    private let contentTextView = UITextView()
    private let dimView = UIView()
    private let cardView = UIView()

    private var hasAnimatedIn = false
    private var isDismissing = false

    static func createDesp(content: String) -> ContentDetailViewController {
        let vc = ContentDetailViewController()
        vc.titleLabel.text = "简介"
        vc.contentTextView.text = content
        // 留在详情页之上，卡片外的区域仍透出原页面，但压暗后只做背景
        vc.modalPresentationStyle = .overFullScreen
        vc.modalTransitionStyle = .crossDissolve
        return vc
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [contentTextView]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        dimView.alpha = 0
        view.addSubview(dimView)
        dimView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackdropTap))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        dimView.addGestureRecognizer(tap)

        // 卡片本身用高不透明度深色底，玻璃只负责边缘质感，不承担正文对比度
        cardView.backgroundColor = UIColor(white: 0.06, alpha: 0.95)
        cardView.layer.cornerRadius = 40
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 1
        cardView.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOpacity = 0.45
        cardView.layer.shadowRadius = 48
        cardView.layer.shadowOffset = CGSize(width: 0, height: 24)
        cardView.alpha = 0
        cardView.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        view.addSubview(cardView)
        cardView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.equalToSuperview().multipliedBy(0.68)
            make.height.equalToSuperview().multipliedBy(0.72)
        }

        titleLabel.font = UIFont.systemFont(ofSize: 52, weight: .semibold)
        titleLabel.textColor = .label
        cardView.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(44)
            make.leading.equalToSuperview().offset(48)
            make.trailing.lessThanOrEqualToSuperview().offset(-48)
        }

        contentTextView.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        contentTextView.isScrollEnabled = true
        contentTextView.isUserInteractionEnabled = true
        contentTextView.isSelectable = true
        contentTextView.backgroundColor = .clear
        contentTextView.textColor = .label
        contentTextView.font = UIFont.systemFont(ofSize: 30)
        contentTextView.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
        contentTextView.showsVerticalScrollIndicator = true
        cardView.addSubview(contentTextView)
        contentTextView.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(28)
            make.leading.trailing.equalToSuperview().inset(48)
            make.bottom.equalToSuperview().offset(-44)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !hasAnimatedIn else { return }
        hasAnimatedIn = true

        UIView.animate(withDuration: 0.45,
                       delay: 0,
                       usingSpringWithDamping: 0.82,
                       initialSpringVelocity: 0.5,
                       options: [.curveEaseOut, .allowUserInteraction])
        {
            self.cardView.alpha = 1
            self.cardView.transform = .identity
        }

        UIView.animate(withDuration: 0.24,
                       delay: 0,
                       options: [.curveEaseOut, .allowUserInteraction])
        {
            self.dimView.alpha = 1
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            dismissWithAnimation()
        } else {
            super.pressesEnded(presses, with: event)
        }
    }

    @objc private func handleBackdropTap() {
        dismissWithAnimation()
    }

    private func dismissWithAnimation() {
        guard !isDismissing else { return }
        isDismissing = true

        UIView.animate(withDuration: 0.22,
                       delay: 0,
                       options: [.curveEaseIn])
        {
            self.cardView.alpha = 0
            self.cardView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            self.dimView.alpha = 0
        } completion: { _ in
            self.dismiss(animated: false)
        }
    }
}
