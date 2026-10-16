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
    /// bilibilitv://video?aid=xxx 进详情页; bilibilitv://play?aid=xxx 直接起播
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
