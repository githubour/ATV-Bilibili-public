//
//  BilibiliVideoResourceLoaderDelegate+Playlist.swift
//  ATV-Bilibili
//
//  清单生成: 单条媒体流（sidx 分片 / 兜底整段 URL）与字幕轨道清单。
//  状态读写都在 delegate 实例上, 与主文件同一把「装配期写入、播放期只读」约定。
//
//  从 BilibiliVideoResourceLoaderDelegate.swift 按职责拆出；为跨文件访问，
//  成员由 private 改为模块内可见，行为不变。
//

import Foundation

extension BilibiliVideoResourceLoaderDelegate {
    func addVideoPlayBackInfo(info: VideoPlayURLInfo.DashInfo.DashMediaInfo, url: String, duration: Int) {
        let isDolby = info.isDolbyVision
        let isHDR10 = info.isHDR10
        // hdr 10 formate exp: hev1.2.4.L156.90
        //  Codec.Profile.Flags.TierLevel.Constraints
        let isHDR = isDolby || isHDR10
        if isHDR {
            self.isHDR = true
        }
        var videoRange: String? = isHDR ? "HLG" : "SDR"
        var codecs = info.codecs
        var supplementCodesc = ""
        let framerate = Self.hlsFrameRate(from: info.frame_rate)
        // 杜比视界的清单声明按 Apple《HLS authoring specification》附录的对照表落表，
        // 见 dolbyVisionDeclaration(forCodecs:)。原先是对 codecs 字符串做等值判断，
        // 查不到就静默留一个猜出来的 HLG —— 附录明确说兼容品牌与 VIDEO-RANGE 互为交叉校验，
        // 填错比不填更糟，所以未识别时干脆不带 VIDEO-RANGE。
        if let declaration = Self.dolbyVisionDeclaration(forCodecs: info.codecs) {
            codecs = declaration.baseCodecs
            supplementCodesc = declaration.supplementary
            videoRange = declaration.videoRange
        } else if info.codecs.hasPrefix("dvh1.") {
            videoRange = nil
            Logger.warn("[hls] 对照表里没有的杜比视界编码，不声明 VIDEO-RANGE: \(info.codecs)")
        } else if isHDR10 {
            videoRange = "PQ"
        } else if isHDR {
            Logger.warn("[hls] unknown hdr codecs: \(info.codecs)")
        }
        // VIDEO-RANGE 是可选属性：查不到对照表时宁可省掉，也不猜
        let videoRangeAttr = videoRange.map { ",VIDEO-RANGE=\($0)" } ?? ""

        if supplementCodesc.count > 0 {
            supplementCodesc = ",SUPPLEMENTAL-CODECS=\"\(supplementCodesc)\""
        }
        // variant 的 CODECS 需覆盖该 variant 用到的全部编码（Apple HLS 规范）。
        // 音频走独立的 EXT-X-MEDIA 组，编码只能在这里声明 —— 不声明时系统在清单层
        // 只看到视频编码，ec-3（杜比全景声）的识别与透传就退化成"看解封装结果"。
        // 取 DEFAULT=YES 那条（audioTracks 首条）的编码。
        let masterCodecs = audioTracks.first.map { "\(codecs),\($0.info.codecs)" } ?? codecs
        // 没有音轨时不引用音频组，避免 AUDIO="audio" 指向不存在的 GROUP-ID
        let leadingAttrs = [
            audioTracks.isEmpty ? nil : "AUDIO=\"audio\"",
            hasSubtitle ? "SUBTITLES=\"subs\"" : nil,
        ].compactMap { $0 }.joined(separator: ",")
        let leading = leadingAttrs.isEmpty ? "" : leadingAttrs + ","
        let content = """
        #EXT-X-STREAM-INF:\(leading)CODECS="\(masterCodecs)"\(supplementCodesc),RESOLUTION=\(info.width ?? 0)x\(info.height ?? 0),FRAME-RATE=\(framerate),BANDWIDTH=\(Self.peakBandwidth(forAverage: info.bandwidth)),AVERAGE-BANDWIDTH=\(info.bandwidth)\(videoRangeAttr)
        \(URLs.customDashPrefix)\(videoInfo.count)?codec=\(info.codecs)&rate=\(info.frame_rate ?? framerate)&width=\(info.width ?? 0)&host=\(URL(string: url)?.host ?? "none")&range=\(info.id)

        """
        masterPlaylist.append(content)
        videoInfo.append(PlaybackInfo(info: info, urls: [url], duration: duration))
    }

    func collectCDNCandidates(from video: VideoPlayURLInfo.DashInfo.DashMediaInfo?) {
        guard let video else {
            setCdnDiagnostics(candidates: [], primaryBandwidth: 0)
            return
        }
        var seenHosts = Set<String>()
        let candidates = video.playableURLs.filter { url in
            guard let host = url.urlHost else { return false }
            return seenHosts.insert(host).inserted
        }
        setCdnDiagnostics(candidates: candidates, primaryBandwidth: video.bandwidth)

        let detail = candidates
            .map { url in
                let host = url.urlHost ?? "?"
                return BVideoUrlUtils.isPCDN(url) ? "  PCDN \(host)" : "  \(host)"
            }
            .joined(separator: "\n")
        Logger.info("cdn candidates for qn \(video.id) (\(video.bandwidth / 1000)kbps):\n\(detail)")
    }

    func getVideoPlayList(info: PlaybackInfo) async -> String {
        let sidxResult = await segmentInfoCache.sidx(from: info.info, preferredHost: preferredHost)
        let inits = info.info.segment_base.initialization.components(separatedBy: "-")
        guard let moovIdxStr = inits.last,
              let moovIdx = Int(moovIdxStr),
              let moovOffset = inits.first,
              let offsetStr = info.info.segment_base.index_range.components(separatedBy: "-").last,
              var offset = Int(offsetStr),
              let sidxResult = sidxResult
        else {
            // 兜底清单：拿不到 sidx 时按候选列表挑一个 URL。音轨带着全部 CDN 候选，
            // 这里会优先跟随播放器当前选中的 host，而不是死绑第一个候选
            let fallbackURL = info.fallbackURL(preferringHost: preferredHost)
            setCurrentSegmentHost(fallbackURL.urlHost)
            return """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:\(info.duration)
            #EXT-X-MEDIA-SEQUENCE:1
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:\(info.duration)
            \(fallbackURL)
            #EXT-X-ENDLIST
            """
        }

        // 使用 sidx 实际下载成功的 URL——它已经完成了对 CDN 可用性的探测，
        // 首选 CDN 挂掉时 segment 会整体切到探测成功的备用 URL
        let segment = sidxResult.sidx
        let segmentURL = sidxResult.url
        setCurrentSegmentHost(segmentURL.urlHost)
        // sidx 索引字节作为跨 CDN 等价性验证的信任锚点：它是播放前已从探测
        // 成功的 URL 取回的原始字节，后续各 CDN 的同区间样本必须与之逐字节一致。
        // 锚点设置与媒体请求并发进行：先到的下载请求在锚点就位前不经验证直接放行
        // （该 host 下次拼接前仍会再验，见 verifyHostEquivalence），不影响正确性。
        if let anchorRange = Self.indexRange(info.info),
           sidxResult.indexBytes.count == anchorRange.length,
           let downloader = proxyRegistry.downloader(for: info.info)
        {
            await downloader.setTrustAnchor(range: anchorRange, bytes: sidxResult.indexBytes)
        }
        // 代理启用且媒体已成功注册时，用本地 HTTP URL 替换 CDN 地址；
        // 保留原 Range、分段持续时间和全部 HLS 标签。SIDX 失败回退分支保持直连。
        let mediaURL = mediaTransportURL(for: info.info) ?? segmentURL
        var playList = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(segment.maxSegmentDuration() ?? info.duration)
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="\(mediaURL)",BYTERANGE="\(moovIdx + 1)@\(moovOffset)"

        """
        offset += 1
        for segInfo in segment.segments {
            let segStr = """
            #EXTINF:\(Double(segInfo.duration) / Double(segment.timescale)),
            #EXT-X-BYTERANGE:\(segInfo.size)@\(offset)
            \(mediaURL)

            """
            playList.append(segStr)
            offset += (segInfo.size)
        }

        playList.append("\n#EXT-X-ENDLIST")

        return playList
    }

    func addAudioPlayBackInfo(plan: AudioTrackPlan, duration: Int) {
        let isFirst = !hasAudioInMasterListAdded
        let defaultStr = isFirst ? "YES" : "NO"

        // CHANNELS 让系统在清单层就识别多声道音轨（5.1 尤其依赖），推导不出时省掉该属性
        let channels = Self.hlsChannels(forCodecs: plan.info.codecs).map { ",CHANNELS=\"\($0)\"" } ?? ""

        let content = """
        #EXT-X-MEDIA:TYPE=AUDIO,DEFAULT=\(defaultStr),AUTOSELECT=YES,GROUP-ID="audio",LANGUAGE="zh",NAME="\(plan.label)"\(channels),URI="\(URLs.customDashPrefix)\(videoInfo.count)"

        """

        masterPlaylist.append(content)

        // 只有在真正添加音轨时才更新状态
        hasAudioInMasterListAdded = true
        videoInfo.append(PlaybackInfo(info: plan.info, urls: plan.urls, duration: duration))
    }

    func addSubtitleData(lang: String, name: String, duration: Int, url: String) {
        // 索引对齐：subtitleLans 与 playlists 必须在同一次调用里各加一项
        subtitleLans.append(lang)
        var lang = lang
        if lang.hasPrefix("ai-") {
            lang = String(lang.dropFirst(3))
        }
        // 字幕轨一律不声明默认: 选中/关闭完全由 SubtitlePlugin 显式管理。
        // 声明 DEFAULT=YES 会让系统在字幕分组加载完成前抢先拉起一条, 闪出字幕。
        let master = """
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="\(lang)",NAME="\(name)",AUTOSELECT=NO,DEFAULT=NO,URI="\(URLs.customPrefix)\(playlists.count)"

        """
        masterPlaylist.append(master)

        let playList = """
        #EXTM3U
        #EXT-X-TARGETDURATION:\(duration)
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:\(duration),

        \(URLs.customSubtitlePrefix)\(url.addingPercentEncoding(withAllowedCharacters: .afURLQueryAllowed) ?? url)
        #EXT-X-ENDLIST

        """
        playlists.append(playList)
    }
}
