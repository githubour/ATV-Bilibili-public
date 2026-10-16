//
//  Colors.swift
//  ATV-Bilibili
//
//  Created by whw on 2022/10/21.
//

import UIKit

extension UIColor {
    /// B 站品牌粉 #FB7299: 进度条填充/当前集标题/封面角标统一取色
    static let bilibiliPink = UIColor(hex: 0xFB7299)

    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex & 0x00FF0000) >> 16) / 255.0
        let g = CGFloat((hex & 0x0000FF00) >> 8) / 255.0
        let b = CGFloat(hex & 0x000000FF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}
