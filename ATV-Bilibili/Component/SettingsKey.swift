//
//  SettingsKey.swift
//  ATV-Bilibili
//
//  所有 UserDefaults key 集中在此，避免散落的字符串字面量。
//  ⚠️ rawValue 即存储 key，改动等同于清空用户设置，禁止随意修改。
//

import Foundation

enum SettingsKey: String, CaseIterable {
    case danmakuStatus = "Settings.danmuStatus"
    case displayStyle = "Settings.displayStyle"
    case directlyEnterVideo = "Settings.direatlyEnterVideo"
    case mediaQuality = "Settings.mediaQuality"
    case mediaPlayerSpeed = "Settings.mediaPlayerSpeed"
    case danmakuArea = "Settings.danmuArea"
    case danmakuSize = "Settings.danmuSize"
    case danmakuAILevel = "Settings.danmuAILevel"
    case danmakuDuration = "Settings.danmuDuration"
    case losslessAudio = "Settings.losslessAudio"
    case preferAvc = "Settings.preferAvc"
    case danmakuMask = "Settings.danmuMask"
    case subtitlePreferLan = "Settings.subtitlePreferLan"
    case vnMask = "Settings.vnMask"
    case contentMatch = "Settings.contentMatch"
    case contentMatchOnlyInHDR = "Settings.contentMatchOnlyInHDR"
    case continuePlay = "Settings.continuePlay"
    case dlnaUUID = "DLNA.uuid"
    case dlnaEnable = "DLNA.enable"
    case continuouslyPlay = "Settings.continouslyPlay"
    case loopPlay = "Settings.loopPlay"
    case autoSkip = "Settings.play.autoSkip"
    case skipIntroAutoEnabled = "Settings.play.skipIntroAutoEnabled"
    case skipOutroAutoEnabled = "Settings.play.skipOutroAutoEnabled"
    case skipMarkersByKey = "Settings.skipMarkers.byKey"
    case showRelatedVideoInCurrentVC = "Settings.showRelatedVideoInCurrentVC"
    case requestHotWithoutCookie = "Settings.requestHotWithoutCookie"
    case areaLimitUnlock = "Settings.arealimit.unlock"
    case areaLimitCustomServer = "Settings.arealimit.customServer"
    case sideMenuAutoSelectChange = "Settings.ui.sideMenuAutoSelectChange"
    case featuredDurationLimit = "Settings.featuredDurationLimit"
    case recommendFeedFlowEnabled = "Settings.recommendFeedFlowEnabled"
    case featuredContentSafetyFilterEnabled = "Settings.featuredContentSafetyFilterEnabled"
    case followsFeedFlowEnabled = "Settings.followsFeedFlowEnabled"
    case enableSponsorBlock = "Settings.SponsorBlockType"
    case enableDanmakuFilter = "Settings.danmuFilter"
    case enableDanmakuRemoveDup = "Settings.danmuRemoveDup"
    case topShelfSource = "Settings.topShelfSource"
    case danmakuAlpha = "Settings.danmuAlpha"
    case danmakuStrokeWidth = "Settings.danmuStrokeWidth"
    case danmakuStrokeAlpha = "Settings.danmuStrokeAlpha"
    case searchHistories = "Search.histories"
    case tabBarPagePlacements = "Settings.tabBarPagePlacements"
    case tabBarFavoriteToPersonalMigration = "Settings.tabBarPlacement.favoriteToPersonalMigrated"
    case danmakuFilters = "VideoDanmuFilter.filters"
    case localDanmakuFilters = "VideoDanmuFilter.localFilters"
    case danmakuFilterLastUpdate = "VideoDanmuFilter.lastUpdate"
}
