//
//  UIViewController+Extensions.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/8/20.
//

import SnapKit
import UIKit

extension UIViewController {
    func topMostViewController() -> UIViewController {
        if let presented = presentedViewController {
            return presented.topMostViewController()
        }

        if let navigation = self as? UINavigationController {
            return navigation.visibleViewController?.topMostViewController() ?? navigation
        }

        if let tab = self as? UITabBarController {
            return tab.selectedViewController?.topMostViewController() ?? tab
        }

        return self
    }

    static func topMostViewController() -> UIViewController {
        guard let root = AppDelegate.shared.mainWindow?.rootViewController else {
            // Scene 尚未连接/已销毁时不要强解包崩溃；投屏等后台入口允许“无窗口可展示”而安全失败。
            Logger.warn("[ui] topMostViewController: mainWindow/rootViewController 不可用")
            return UIViewController()
        }
        return root.topMostViewController()
    }
}

// MARK: - 弹窗

extension UIViewController {
    /// 单按钮信息弹窗
    func presentAlert(title: String,
                      message: String? = nil,
                      buttonTitle: String = "好",
                      onDismiss: (() -> Void)? = nil)
    {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: buttonTitle, style: .cancel) { _ in onDismiss?() })
        present(alert, animated: true)
    }

    /// 错误弹窗，默认记一条 warn 日志。dismissSelf 为 true 时点击后关闭当前页面
    func presentError(_ error: Error,
                      title: String = "出错了",
                      dismissSelf: Bool = false,
                      onDismiss: (() -> Void)? = nil)
    {
        Logger.warn(error)
        // 优先用错误自带的本地化描述（RequestError 已把业务码翻成可读文案），否则回落到枚举描述
        let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        let alert = UIAlertController(title: title, message: detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel) { [weak self] _ in
            if dismissSelf {
                self?.dismiss(animated: true)
            }
            onDismiss?()
        })
        present(alert, animated: true)
    }

    /// 二次确认弹窗（默认红色确认按钮）
    func presentConfirm(title: String,
                        message: String? = nil,
                        confirmTitle: String = "确定",
                        cancelTitle: String = "取消",
                        onConfirm: @escaping () -> Void)
    {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: confirmTitle, style: .destructive) { _ in onConfirm() })
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel))
        present(alert, animated: true)
    }

    /// 轻提示浮层：自动淡出，不打断当前操作，也不参与焦点引擎
    func presentToast(_ text: String, duration: TimeInterval = 1.6) {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 26, weight: .medium)
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        label.isUserInteractionEnabled = false
        label.alpha = 0
        view.addSubview(label)
        label.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide.snp.bottom).inset(80)
            make.height.equalTo(64)
            make.width.greaterThanOrEqualTo(300)
            make.width.lessThanOrEqualTo(view.snp.width).multipliedBy(0.7)
        }
        UIView.animate(withDuration: 0.2) {
            label.alpha = 1
        }
        UIView.animate(withDuration: 0.4, delay: duration, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}
