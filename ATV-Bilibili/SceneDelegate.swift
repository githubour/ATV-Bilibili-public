//
//  SceneDelegate.swift
//  ATV-Bilibili
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        // 暗色影院风：固定深色外观，避免系统浅色把评论卡等语义色翻成白底
        window.overrideUserInterfaceStyle = .dark
        // 页面本身大多不铺底色（靠语义色/材质），日间模式下会透出系统浅色底，
        // 白字压白底（用户 2026-11-01 反馈推荐卡片与左侧栏）。窗口兜一层固定深色。
        window.backgroundColor = UIColor(white: 0.06, alpha: 1)
        self.window = window

        if ApiRequest.isLogin() {
            if let expireDate = ApiRequest.getToken()?.expireDate {
                let now = Date()
                if expireDate.timeIntervalSince(now) < 60 * 60 * 30 {
                    Task { await ApiRequest.refreshToken() }
                }
            } else {
                Task { await ApiRequest.refreshToken() }
            }
            window.rootViewController = BLTabBarViewController()
        } else {
            window.rootViewController = LoginViewController.create()
        }
        window.makeKeyAndVisible()
        handleOpenURLContexts(connectionOptions.urlContexts)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        TopShelfSyncManager.shared.refresh()
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handleOpenURLContexts(URLContexts)
    }

    /// 处理 Top Shelf 点击回跳:
    /// bilibilitv://video?aid=xxx 进详情页; bilibilitv://play?aid=xxx 直接起播。
    /// 深链只带 aid，cid 未知：直进由详情页解析出真实分 P/断点后再起播
    /// （番剧/课程解析后留在详情页选集），不会拿 pagelist 的第 1P 硬播。
    private func handleOpenURLContexts(_ contexts: Set<UIOpenURLContext>) {
        guard let url = contexts.first?.url,
              url.scheme == "bilibilitv",
              ApiRequest.isLogin(),
              url.host == "video" || url.host == "play"
        else { return }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let aid = Int(items.first(where: { $0.name == "aid" })?.value ?? "0") ?? 0
        guard aid > 0 else { return }

        let detailVC = VideoDetailViewController.create(aid: aid, cid: 0)
        detailVC.present(from: UIViewController.topMostViewController(),
                         directlyEnterVideo: url.host == "play")
    }

    func showLogin() {
        replaceRootViewController(with: LoginViewController.create(), animated: false)
    }

    func showTabBar() {
        replaceRootViewController(with: BLTabBarViewController(), animated: false)
    }

    func resetTabBar() {
        replaceRootViewController(with: BLTabBarViewController(), animated: true)
    }

    private func replaceRootViewController(with viewController: UIViewController, animated: Bool) {
        guard let window else { return }
        if animated, let snapshot = window.snapshotView(afterScreenUpdates: false) {
            window.rootViewController = viewController
            window.makeKeyAndVisible()
            viewController.view.addSubview(snapshot)
            UIView.animate(withDuration: 0.25, animations: {
                snapshot.alpha = 0
            }, completion: { _ in
                snapshot.removeFromSuperview()
            })
        } else {
            window.rootViewController = viewController
            window.makeKeyAndVisible()
        }
    }
}
