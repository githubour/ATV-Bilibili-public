//
//  Kingfisher+Avatar.swift
//  ATV-Bilibili
//

import Kingfisher
import UIKit

extension KingfisherOptionsInfo where Self == [KingfisherOptionsInfoItem] {
    /// 头像统一加载参数：80×80 降采样 + 圆形裁剪 + PNG 缓存序列化（全仓库头像处共用）
    static var avatar: [KingfisherOptionsInfoItem] {
        [
            .processor(DownsamplingImageProcessor(size: CGSize(width: 80, height: 80))),
            .processor(RoundCornerImageProcessor(radius: .widthFraction(0.5))),
            .cacheSerializer(FormatIndicatedCacheSerializer.png),
        ]
    }

    /// 封面统一加载参数: 按目标显示尺寸降采样 + 缓存原图 (feed/相关推荐/选集卡共用)
    static func cover(width: CGFloat, height: CGFloat) -> [KingfisherOptionsInfoItem] {
        [
            .processor(DownsamplingImageProcessor(size: CGSize(width: width, height: height))),
            .cacheOriginalImage,
        ]
    }
}

extension UIImageView {
    /// 账号头像: 空/坏 URL 落系统占位图标; 返回是否用了占位 (调用方按需补占位配色)。
    /// 不带 .avatar 参数 —— 大尺寸头像位 (个人页/账号卡 160pt) 降采样到 80 会糊。
    @discardableResult
    func setAccountAvatar(with urlString: String) -> Bool {
        if let url = URL(string: urlString), !urlString.isEmpty {
            kf.setImage(with: url)
            return false
        }
        image = UIImage(systemName: "person.crop.circle.fill")
        return true
    }
}
