//
//  BilibiliVideoResourceLoaderDelegateTests.swift
//  ATV-BilibiliTests
//

@testable import ATV_Bilibili
import XCTest

/// 覆盖资源加载器里"生成 HLS 清单"的纯规则，以及装配出的 master playlist 结构。
/// 这几处过去只能靠真机播放来验证：音轨声道数/编码声明、音轨命名、帧率声明。
final class BilibiliVideoResourceLoaderDelegateTests: XCTestCase {
    private let dolbyVision = "dvh1.08.06"
    private let hdr10 = "hev1.2.4.L120.90"
    private let hevc = "hev1.1.6.L120.90"
    private let avc = "avc1.640034"

    private func makeVideo(id: Int,
                           bandwidth: Int,
                           codecs: String,
                           frameRate: String? = nil) -> VideoPlayURLInfo.DashInfo.DashMediaInfo
    {
        .init(id: id, base_url: "https://cdn.example.com/v.m4s", backup_url: nil,
              bandwidth: bandwidth, mime_type: "video/mp4", codecs: codecs,
              width: 3840, height: 2160, frame_rate: frameRate, sar: nil, start_with_sap: nil,
              segment_base: .init(initialization: "0-999", index_range: "1000-1999"), codecid: nil)
    }

    private func makeAudio(id: Int,
                           bandwidth: Int,
                           codecs: String) -> VideoPlayURLInfo.DashInfo.DashMediaInfo
    {
        .init(id: id, base_url: "https://cdn.example.com/a.m4s", backup_url: nil,
              bandwidth: bandwidth, mime_type: "audio/mp4", codecs: codecs,
              width: nil, height: nil, frame_rate: nil, sar: nil, start_with_sap: nil,
              segment_base: .init(initialization: "0-999", index_range: "1000-1999"), codecid: nil)
    }

    private func makeDash(video: [VideoPlayURLInfo.DashInfo.DashMediaInfo],
                          audio: [VideoPlayURLInfo.DashInfo.DashMediaInfo]? = nil,
                          dolby: VideoPlayURLInfo.DashInfo.DolbyInfo? = nil,
                          flac: VideoPlayURLInfo.DashInfo.FlacInfo? = nil) -> VideoPlayURLInfo.DashInfo
    {
        .init(duration: 60, minBufferTime: 1.5, video: video, audio: audio, dolby: dolby, flac: flac)
    }

    private func makePlayURLInfo(dash: VideoPlayURLInfo.DashInfo) -> VideoPlayURLInfo {
        .init(quality: 126, format: "dash", timelength: 60000, accept_format: "dash",
              accept_description: [], accept_quality: [], video_codecid: 7,
              support_formats: [], dash: dash, clip_info_list: nil)
    }

    private func renderMasterPlaylist(dash: VideoPlayURLInfo.DashInfo) -> String {
        let delegate = BilibiliVideoResourceLoaderDelegate()
        // 用 streamIndex 直接锁定 dash.video[0]，绕开画质上限过滤
        // （选流规则本身由 BVideoStreamSelectionTests 覆盖）
        delegate.setBilibili(info: makePlayURLInfo(dash: dash), subtitles: [], aid: 1, streamIndex: 0)
        return delegate.masterPlaylist
    }

    // MARK: - hlsFrameRate

    func test_hlsFrameRate_passesThroughInsteadOfClampingTo30() {
        // HDR10 60fps 曾被截断成 30：该声明参与显示模式匹配，误报会让电视切到 30Hz 档
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.hlsFrameRate(from: "60.000"), "60.000")
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.hlsFrameRate(from: "59.940"), "59.940")
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.hlsFrameRate(from: "30.303"), "30.303")
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.hlsFrameRate(from: "23.810"), "23.810")
    }

    func test_hlsFrameRate_fallsBackWhenMissingOrNotNumeric() {
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.hlsFrameRate(from: nil), "25")
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.hlsFrameRate(from: "abc"), "25")
    }

    // MARK: - hlsChannels

    func test_hlsChannels_mapsDolbyTo5_1AndOthersToStereo() {
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.hlsChannels(forCodecs: "ec-3"), 6)
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.hlsChannels(forCodecs: "ac-3"), 6)
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.hlsChannels(forCodecs: "mp4a.40.2"), 2)
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.hlsChannels(forCodecs: "mp4a.40.5"), 2)
        XCTAssertEqual(BilibiliVideoResourceLoaderDelegate.hlsChannels(forCodecs: "fLaC"), 2)
        // 认不出就不声明该属性，而不是猜一个值
        XCTAssertNil(BilibiliVideoResourceLoaderDelegate.hlsChannels(forCodecs: "hvc1.2.4.L150"))
    }

    // MARK: - planAudioTracks

    func test_planAudioTracks_dolbyFirstThenPlainAudio() {
        let dolby = VideoPlayURLInfo.DashInfo.DolbyInfo(
            type: 2, audio: [makeAudio(id: 30250, bandwidth: 448_000, codecs: "ec-3")]
        )
        let dash = makeDash(video: [makeVideo(id: 120, bandwidth: 8_000_000, codecs: hevc)],
                            audio: [makeAudio(id: 30280, bandwidth: 241_000, codecs: "mp4a.40.2")],
                            dolby: dolby)
        let plans = BilibiliVideoResourceLoaderDelegate.planAudioTracks(for: dash, includeLossless: true)
        // 杜比在前 → 成为 DEFAULT=YES 的起播音轨
        XCTAssertEqual(plans.map(\.info.id), [30250, 30280])
        XCTAssertTrue(plans[0].label.hasPrefix("杜比全景声"), plans[0].label)
        XCTAssertTrue(plans[1].label.hasPrefix("立体声"), plans[1].label)
    }

    func test_planAudioTracks_losslessOffKeepsOnlyPlainAudio() {
        let dolby = VideoPlayURLInfo.DashInfo.DolbyInfo(
            type: 2, audio: [makeAudio(id: 30250, bandwidth: 448_000, codecs: "ec-3")]
        )
        let dash = makeDash(video: [makeVideo(id: 120, bandwidth: 8_000_000, codecs: hevc)],
                            audio: [makeAudio(id: 30280, bandwidth: 241_000, codecs: "mp4a.40.2")],
                            dolby: dolby)
        let plans = BilibiliVideoResourceLoaderDelegate.planAudioTracks(for: dash, includeLossless: false)
        XCTAssertEqual(plans.map(\.info.id), [30280])
    }

    func test_planAudioTracks_plainAudioPicksHighestBandwidthNotFirst() {
        // B 站 dash.audio 数组顺序不固定：实测同一视频两次请求分别为
        // [30232,30280,30216] 与 [30232,30216,30280]，取 .first 会稳定丢掉最高档
        let dash = makeDash(
            video: [makeVideo(id: 120, bandwidth: 8_000_000, codecs: hevc)],
            audio: [makeAudio(id: 30232, bandwidth: 132_000, codecs: "mp4a.40.2"),
                    makeAudio(id: 30280, bandwidth: 241_000, codecs: "mp4a.40.2"),
                    makeAudio(id: 30216, bandwidth: 67_000, codecs: "mp4a.40.2")]
        )
        let plans = BilibiliVideoResourceLoaderDelegate.planAudioTracks(for: dash, includeLossless: true)
        XCTAssertEqual(plans.map(\.info.id), [30280])
    }

    func test_planAudioTracks_flacUsedWhenNoDolby() {
        let flac = VideoPlayURLInfo.DashInfo.FlacInfo(
            display: true, audio: makeAudio(id: 30251, bandwidth: 1_809_000, codecs: "fLaC")
        )
        let dash = makeDash(video: [makeVideo(id: 120, bandwidth: 8_000_000, codecs: hevc)],
                            audio: [makeAudio(id: 30280, bandwidth: 241_000, codecs: "mp4a.40.2")],
                            flac: flac)
        let plans = BilibiliVideoResourceLoaderDelegate.planAudioTracks(for: dash, includeLossless: true)
        XCTAssertEqual(plans.map(\.info.id), [30251, 30280])
        XCTAssertTrue(plans[0].label.hasPrefix("Hi-Res 无损"), plans[0].label)
    }

    func test_planAudioTracks_emptyWhenNothingAvailable() {
        let dash = makeDash(video: [makeVideo(id: 120, bandwidth: 8_000_000, codecs: hevc)])
        XCTAssertTrue(BilibiliVideoResourceLoaderDelegate.planAudioTracks(for: dash, includeLossless: true).isEmpty)
    }

    // MARK: - dolbyVisionDeclaration（Apple HLS 附录对照表）

    func test_dolbyVision_profile5_keepsCodecAndDeclaresPQWithoutSupplemental() {
        // Profile 5 是单层 10-bit HEVC、不向后兼容：CODECS 保持原值，不加 SUPPLEMENTAL-CODECS
        let declaration = BilibiliVideoResourceLoaderDelegate.dolbyVisionDeclaration(forCodecs: "dvh1.05.07")
        XCTAssertEqual(declaration?.baseCodecs, "dvh1.05.07")
        XCTAssertEqual(declaration?.supplementary, "")
        XCTAssertEqual(declaration?.videoRange, "PQ")
    }

    func test_dolbyVision_profile8HLGCompatible() {
        // 附录：Dolby Vision 8.4 → hvc1.2.4.L153.b0 / dvh1.08.07/db4h / HLG
        for codecs in ["dvh1.08.03", "dvh1.08.07"] {
            let declaration = BilibiliVideoResourceLoaderDelegate.dolbyVisionDeclaration(forCodecs: codecs)
            XCTAssertEqual(declaration?.baseCodecs, "hvc1.2.4.L153.b0", codecs)
            XCTAssertEqual(declaration?.supplementary, ",SUPPLEMENTAL-CODECS=\"\(codecs)/db4h\"", codecs)
            XCTAssertEqual(declaration?.videoRange, "HLG", codecs)
        }
    }

    func test_dolbyVision_profile8HDR10Compatible() {
        // 附录：Dolby Vision 8.1 → hvc1.2.4.L150 / dvh1.08.06/db1p / PQ
        let declaration = BilibiliVideoResourceLoaderDelegate.dolbyVisionDeclaration(forCodecs: "dvh1.08.06")
        XCTAssertEqual(declaration?.baseCodecs, "hvc1.2.4.L150")
        XCTAssertEqual(declaration?.supplementary, ",SUPPLEMENTAL-CODECS=\"dvh1.08.06/db1p\"")
        XCTAssertEqual(declaration?.videoRange, "PQ")
    }

    func test_dolbyVision_unlistedProfileReturnsNilInsteadOfGuessing() {
        // 附录写明兼容品牌与 VIDEO-RANGE 互为交叉校验，缺任何一个都是错的：
        // 查不到就返回 nil，让调用方省掉该属性，而不是编一个动态范围出来
        XCTAssertNil(BilibiliVideoResourceLoaderDelegate.dolbyVisionDeclaration(forCodecs: "dvh1.08.05"))
        XCTAssertNil(BilibiliVideoResourceLoaderDelegate.dolbyVisionDeclaration(forCodecs: "dvh1.09.06"))
        XCTAssertNil(BilibiliVideoResourceLoaderDelegate.dolbyVisionDeclaration(forCodecs: "dvh1.08"))
        XCTAssertNil(BilibiliVideoResourceLoaderDelegate.dolbyVisionDeclaration(forCodecs: hevc))
        XCTAssertNil(BilibiliVideoResourceLoaderDelegate.dolbyVisionDeclaration(forCodecs: hdr10))
    }

    func test_masterPlaylist_unlistedDolbyVisionOmitsVideoRange() {
        let dash = makeDash(video: [makeVideo(id: 126, bandwidth: 40_000_000, codecs: "dvh1.08.05", frameRate: "23.810")],
                            audio: [makeAudio(id: 30280, bandwidth: 241_000, codecs: "mp4a.40.2")])
        let master = renderMasterPlaylist(dash: dash)
        XCTAssertFalse(master.contains("VIDEO-RANGE"), master)
        XCTAssertFalse(master.contains("SUPPLEMENTAL-CODECS"), master)
        XCTAssertTrue(master.contains("CODECS=\"dvh1.08.05"), master)
    }

    // MARK: - master playlist 结构

    func test_masterPlaylist_declaresAudioCodecAndChannelsForDolby() throws {
        let dolby = VideoPlayURLInfo.DashInfo.DolbyInfo(
            type: 2, audio: [makeAudio(id: 30250, bandwidth: 448_000, codecs: "ec-3")]
        )
        let dash = makeDash(video: [makeVideo(id: 126, bandwidth: 40_000_000, codecs: dolbyVision, frameRate: "23.810")],
                            audio: [makeAudio(id: 30280, bandwidth: 241_000, codecs: "mp4a.40.2")],
                            dolby: dolby)
        let master = renderMasterPlaylist(dash: dash)

        // variant 的 CODECS 必须带上音频编码，否则系统在清单层只看得到视频编码
        XCTAssertTrue(master.contains("CODECS=\"hvc1.2.4.L150,ec-3\""), master)
        XCTAssertTrue(master.contains("SUPPLEMENTAL-CODECS=\"dvh1.08.06/db1p\""), master)
        XCTAssertTrue(master.contains("AUDIO=\"audio\""), master)
        XCTAssertTrue(master.contains("VIDEO-RANGE=PQ"), master)

        // 多声道音轨在清单层就声明出来，5.1 依赖它
        XCTAssertTrue(master.contains("CHANNELS=\"6\""), master)
        XCTAssertTrue(master.contains("NAME=\"杜比全景声 (ec-3, 448kbps)\""), master)
        XCTAssertTrue(master.contains("CHANNELS=\"2\""), master)
        XCTAssertTrue(master.contains("NAME=\"立体声 (AAC, 241kbps)\""), master)

        // 首条音轨才是起播音轨
        XCTAssertTrue(master.contains("DEFAULT=YES,AUTOSELECT=YES,GROUP-ID=\"audio\",LANGUAGE=\"zh\",NAME=\"杜比全景声"), master)
        XCTAssertTrue(master.contains("DEFAULT=NO,AUTOSELECT=YES,GROUP-ID=\"audio\",LANGUAGE=\"zh\",NAME=\"立体声"), master)
    }

    func test_masterPlaylist_keeps60fpsForHDR10() {
        let dash = makeDash(video: [makeVideo(id: 125, bandwidth: 30_000_000, codecs: hdr10, frameRate: "60.000")],
                            audio: [makeAudio(id: 30280, bandwidth: 241_000, codecs: "mp4a.40.2")])
        let master = renderMasterPlaylist(dash: dash)
        XCTAssertTrue(master.contains("FRAME-RATE=60.000,"), master)
        XCTAssertTrue(master.contains("VIDEO-RANGE=PQ"), master)
    }

    func test_masterPlaylist_omitsAudioGroupWhenNoAudioStreams() {
        let dash = makeDash(video: [makeVideo(id: 120, bandwidth: 8_000_000, codecs: hevc, frameRate: "23.810")])
        let master = renderMasterPlaylist(dash: dash)
        // 没有音轨时不能引用不存在的 AUDIO 组，也不能留下悬空逗号
        XCTAssertTrue(master.contains("#EXT-X-STREAM-INF:CODECS="), master)
        XCTAssertFalse(master.contains("AUDIO=\"audio\""), master)
        XCTAssertFalse(master.contains("CHANNELS="), master)
        XCTAssertFalse(master.contains("TYPE=AUDIO"), master)
        XCTAssertTrue(master.contains("FRAME-RATE=23.810"), master)
        XCTAssertTrue(master.contains("VIDEO-RANGE=SDR"), master)
    }

    func test_masterPlaylist_avcOnlyVideoKeepsVideoCodecsAlone() {
        let dash = makeDash(video: [makeVideo(id: 80, bandwidth: 2_000_000, codecs: avc, frameRate: "30.303")],
                            audio: [makeAudio(id: 30280, bandwidth: 241_000, codecs: "mp4a.40.2")])
        let master = renderMasterPlaylist(dash: dash)
        XCTAssertTrue(master.contains("CODECS=\"avc1.640034,mp4a.40.2\""), master)
        XCTAssertTrue(master.contains("FRAME-RATE=30.303"), master)
    }
}
