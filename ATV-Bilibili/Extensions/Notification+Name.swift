//
//  Notification+Name.swift
//  ATV-Bilibili
//
//  全app的 Notification.Name 集中在此，避免裸字符串。
//

import Foundation

extension Notification.Name {
    static let tabBarPagesDidChange = Notification.Name("BLTabBarViewController.tabBarPagesDidChange")
    static let followsLayoutModeDidChange = Notification.Name("FollowsViewController.layoutModeDidChange")
    static let accountDidUpdate = Notification.Name("AccountManagerDidUpdate")
}
