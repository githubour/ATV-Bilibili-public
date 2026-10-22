//
//  AppDelegate.swift
//  ATV-Bilibili
//
//  Created by Etan on 2021/3/27.
//

import AVFoundation
import CocoaLumberjackSwift
import Kingfisher
import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    // 不命名 window: 避免触发与 UIApplicationDelegate.window 可选要求(UIScene 时代已无实现必要)的近似匹配警告
    var mainWindow: UIWindow? {
        sceneDelegate?.window
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Logger.setup()
        ImageCache.default.diskStorage.config.sizeLimit = 500 * 1024 * 1024
        AccountManager.shared.bootstrap()
        BiliBiliUpnpDMR.shared.start()
        // 首页请求只用于让服务端回种匿名 cookie 并回写账号 cookie；未登录(还在登录页)时没必要在冷启动抢带宽
        if ApiRequest.isLogin() {
            WebRequest.requestIndex()
        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAccountSwitch),
                                               name: .accountDidSwitch,
                                               object: nil)
        return true
    }

    /// 换号后清理随账号走的缓存：弹幕云屏蔽词（下次进弹幕页会重新同步）+ 图片缓存（避免头像/封面混号）
    @objc private func handleAccountSwitch() {
        VideoDanmakuFilter.shared.resetCloudRules()
        ImageCache.default.clearMemoryCache()
        ImageCache.default.clearDiskCache()
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    func showLogin() {
        sceneDelegate?.showLogin()
    }

    /// 登录态过期时优先以可取消的 modal 打开登录页：
    /// 账号还存在（可切号/重试），不应把根 VC 直接换成无法返回的登录页。
    func showLoginForExpiredSession() {
        if UIViewController.topMostViewController() is LoginViewController { return }
        guard !AccountManager.shared.accounts.isEmpty else {
            showLogin()
            return
        }
        let login = LoginViewController.create()
        login.modalPresentationStyle = .fullScreen
        login.onCancel = { [weak login] in
            login?.dismiss(animated: true)
        }
        UIViewController.topMostViewController().present(login, animated: true)
    }

    func showTabBar() {
        sceneDelegate?.showTabBar()
    }

    func resetTabBar() {
        sceneDelegate?.resetTabBar()
    }

    static var shared: AppDelegate {
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else {
            // 只在 Info.plist 未把该类设为 AppDelegate 时才会走到，属于工程配置错误
            fatalError("UIApplication.shared.delegate 不是 AppDelegate，请检查 Info.plist 配置")
        }
        return delegate
    }

    private var sceneDelegate: SceneDelegate? {
        UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.first
    }
}
