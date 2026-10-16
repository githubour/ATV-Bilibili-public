//
//  IntroOutroMarkers.swift
//  ATV-Bilibili
//
//  用户手动标记的片头/片尾跳过点，按内容键持久化：
//  番剧按 season_id 记忆（同一部番所有集共用同一组标记点），
//  普通视频按 aid 记忆。片头标记 = 片头结束时刻；片尾标记 = 片尾开始时刻。
//

import Foundation

struct SkipMarkers: Codable, Equatable {
    /// 片头结束时刻（秒）：播放越过该点即为正片
    var introSeconds: Double?
    /// 片尾开始时刻（秒）：播放到该点即进入片尾
    var outroSeconds: Double?
    /// 标记片尾时该集的总时长，跨集套用时用于校验时长是否接近（OP/ED 长度相近才适用）
    var outroDuration: Double?
}

enum SkipMarkerStore {
    private static let storageKey = SettingsKey.skipMarkersByKey.rawValue
    /// 持久化存储（测试注入独立 suite，生产用 standard）
    static var storage: UserDefaults = .standard

    /// 番剧按季记忆，普通视频按 aid
    static func key(for playInfo: PlayInfo) -> String {
        if let seasonId = playInfo.seasonId, seasonId > 0 {
            return "season-\(seasonId)"
        }
        return "aid-\(playInfo.aid)"
    }

    static func markers(for playInfo: PlayInfo) -> SkipMarkers {
        all()[key(for: playInfo)] ?? SkipMarkers(introSeconds: nil, outroSeconds: nil, outroDuration: nil)
    }

    static func setIntro(_ seconds: Double?, for playInfo: PlayInfo) {
        update(for: playInfo) { $0.introSeconds = seconds }
    }

    static func setOutro(_ seconds: Double?, duration: Double?, for playInfo: PlayInfo) {
        update(for: playInfo) {
            $0.outroSeconds = seconds
            $0.outroDuration = seconds == nil ? nil : duration
        }
    }

    private static func update(for playInfo: PlayInfo, mutate: (inout SkipMarkers) -> Void) {
        var all = all()
        var markers = all[key(for: playInfo)] ?? SkipMarkers(introSeconds: nil, outroSeconds: nil, outroDuration: nil)
        mutate(&markers)
        all[key(for: playInfo)] = markers
        guard let data = try? JSONEncoder().encode(all) else { return }
        storage.set(data, forKey: storageKey)
    }

    private static func all() -> [String: SkipMarkers] {
        guard let data = storage.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: SkipMarkers].self, from: data)) ?? [:]
    }
}

/// 跨集标记点换算（自 IntroOutroSkipPlugin 迁入的同域纯函数，供单元测试直接覆盖）。
enum SkipMarkerResolver {
    /// 片尾跨集套用的时长容差（秒）：标记时记录的片长与当前片长相差超过该值时按 ED 长度换算
    static let durationTolerance: Double = 20

    /// 把存储的标记点换算成当前集的绝对时刻。
    /// 片头：绝对秒直接沿用（同番各集 OP 长度通常一致）。
    /// 片尾：优先按「记录片长 - 标记时刻 = ED 长度」用当前片长回推；
    ///       没记录片长或片长接近（±20s）时退回绝对时刻。
    static func resolveMarkers(_ stored: SkipMarkers, duration: Double) -> SkipMarkers {
        var resolved = stored
        if let outro = stored.outroSeconds {
            if let recordedDuration = stored.outroDuration, recordedDuration > 0 {
                if abs(recordedDuration - duration) <= durationTolerance {
                    resolved.outroSeconds = outro
                } else {
                    let edLength = recordedDuration - outro
                    resolved.outroSeconds = (edLength > 0 && edLength < duration) ? duration - edLength : nil
                }
            } else {
                resolved.outroSeconds = outro
            }
        }
        return resolved
    }
}
