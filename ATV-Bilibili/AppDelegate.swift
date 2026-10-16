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
        AVInfoPanelCollectionViewThumbnailCellHook.start()
        AccountManager.shared.bootstrap()
        BiliBiliUpnpDMR.shared.start()
        WebRequest.requestIndex()
        return true
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
