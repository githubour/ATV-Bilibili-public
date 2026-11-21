//
//  BLTabBarViewController+RefreshHint.swift
//  ATV-Bilibili
//
//  从 BLTabBarViewController.swift 抽出（2026-10-31 审核行动项），零行为变化。
//

import SnapKit
import UIKit

// 播放/暂停键刷新提示浮层

extension BLTabBarViewController {
    /// 主页左下角短暂显示「按播放/暂停键刷新」提示, 每次启动只显示一次
    func showPlayPauseHintIfNeeded() {
        guard !refreshHintShown else { return }
        refreshHintShown = true

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        guard let icon = UIImage(systemName: "playpause", withConfiguration: symbolConfig) else { return }

        let hintView = UIView()
        hintView.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        hintView.layer.cornerRadius = 10
        hintView.isUserInteractionEnabled = false

        let imageView = UIImageView(image: icon)
        imageView.tintColor = .white
        imageView.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = "按此键刷新"
        label.textColor = .white
        label.font = .systemFont(ofSize: 24, weight: .medium)

        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center

        hintView.addSubview(stack)
        view.addSubview(hintView)
        hintView.alpha = 0

        hintView.snp.makeConstraints { make in
            make.leading.equalTo(view.safeAreaLayoutGuide).offset(40)
            make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-40)
        }
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 20))
        }

        UIView.animate(withDuration: 0.25) {
            hintView.alpha = 1
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            UIView.animate(withDuration: 0.4, animations: {
                hintView.alpha = 0
            }, completion: { _ in
                hintView.removeFromSuperview()
            })
        }
    }
}
