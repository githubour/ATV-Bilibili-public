//
//  BuildInfo.swift
//  ATV-Bilibili
//
//  版本戳: 每个代码批次推送后更新一次(哈希指向该批次最终代码提交, 会落后纯元数据提交)
//  commitHash/commitCount 供设置页「关于」展示, 用于排障时定位电视上实际安装的批次
//

enum BuildInfo {
    /// 营销版本, 与两个 target 的 Info.plist CFBundleShortVersionString 保持一致
    static let marketingVersion = "1.2.0"
    /// 构建号 = git 提交数, 与两个 target 的 Info.plist CFBundleVersion 保持一致
    static let buildNumber = 566
    /// 版本戳对应的代码提交
    static let commitHash = "40e25c3"
}
