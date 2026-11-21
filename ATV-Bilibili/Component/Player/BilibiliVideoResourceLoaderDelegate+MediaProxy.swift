//
//  BilibiliVideoResourceLoaderDelegate+MediaProxy.swift
//  ATV-Bilibili
//
//  自定义 scheme 分发（atv://list / atv://dash / atv://subtitle）与本地 HTTP 媒体代理:
//  只接受当前会话已注册的媒体 id, 不接受外部 URL; 206 发出后只允许补齐或截断。
//
//  从 BilibiliVideoResourceLoaderDelegate.swift 按职责拆出。原为 private extension,
//  拆开后成员改为模块内可见（主文件的 setBilibili 需要调用 bindHttpServer 等）。
//

import AVFoundation
import Swifter
import UIKit

extension BilibiliVideoResourceLoaderDelegate {
    func handleCustomPlaylistRequest(_ loadingRequest: AVAssetResourceLoadingRequest) {
        guard let customUrl = loadingRequest.request.url else {
            reportError(loadingRequest, withErrorCode: badRequestErrorCode)
            return
        }
        let urlStr = customUrl.absoluteString
        if urlStr == URLs.play {
            Logger.debug("handleCustomPlaylistRequest: \(urlStr)")
            report(loadingRequest, content: masterPlaylist)
            return
        }

        if urlStr.hasPrefix(URLs.customPrefix), let index = Int(customUrl.lastPathComponent) {
            // 压制 tvOS 在**暂停 / 回看**时的自动选轨。
            //
            // 实测证据（真机 /debug/log）：播放中途 17:14:33 出现 atv://list/0 请求并拉走字幕片段，
            // 而当时既没有换 item、也没有 resume，App 侧没有任何选轨调用（选轨只有三处：
            // 换 item、起播/恢复、手动点菜单），设备上 subtitleAutoSelect=false、preferLan 为空
            // —— 是 AVKit 自己挑了一条轨拉起来显示（Apple TV 上"回看自动弹字幕"的同一套行为）。
            // 这种系统行为无法用 AVMediaSelection 关掉，只能在数据层让它无内容可显示。
            //
            // 只放行用户在菜单里明确选中的那条轨；其余一律回空清单。
            let wanted = Self.wantedSubtitleLan(autoSelect: Settings.subtitleAutoSelect,
                                                preferLan: Settings.subtitlePreferLan)
            let wantedLan = wanted.flatMap {
                Self.resolvedSubtitleLan(preference: $0, availableLans: subtitleLans)
            }
            guard subtitleLans.indices.contains(index), playlists.indices.contains(index) else {
                Logger.warn("[subtitle] 越界清单请求 index=\(index) count=\(subtitleLans.count)")
                reportError(loadingRequest, withErrorCode: badRequestErrorCode)
                return
            }
            if subtitleLans[index] != wantedLan {
                logSubtitleIntercept(lan: subtitleLans[index], wanted: wantedLan)
                report(loadingRequest, content: emptySubtitlePlaylistForIntercept())
                return
            }
            Logger.debug("[subtitle] 放行用户所选字幕清单: \(subtitleLans[index])")
            report(loadingRequest, content: playlists[index])
            return
        }
        if urlStr.hasPrefix(URLs.customDashPrefix), let index = Int(customUrl.lastPathComponent) {
            guard videoInfo.indices.contains(index) else {
                Logger.warn("[dash] 越界清单请求 index=\(index) count=\(videoInfo.count)")
                reportError(loadingRequest, withErrorCode: badRequestErrorCode)
                return
            }
            let info = videoInfo[index]
            Task {
                report(loadingRequest, content: await getVideoPlayList(info: info))
            }
        }
        if urlStr.hasPrefix(URLs.customSubtitlePrefix) {
            let url = String(urlStr.dropFirst(URLs.customSubtitlePrefix.count))
            let req = url.removingPercentEncoding ?? url
            guard let subtitleURL = URL(string: req) else {
                loadingRequest.finishLoading(with: URLError(.badURL))
                return
            }
            Task {
                do {
                    if !hasSubtitleVTT(for: req) {
                        let content = try await WebRequest.requestSubtitle(url: subtitleURL)
                        let vtt = BVideoUrlUtils.convertToVTT(subtitle: content)
                        storeSubtitleVTT(vtt, for: req)
                    }
                    let port = try self.httpServer.port()
                    let redirectURLString = "http://127.0.0.1:\(port)/subtitle?u=" + url
                    guard let redirectURL = URL(string: redirectURLString) else {
                        throw URLError(.badURL)
                    }
                    let redirectRequest = URLRequest(url: redirectURL)
                    let redirectResponse = HTTPURLResponse(url: redirectURL, statusCode: 302, httpVersion: nil, headerFields: nil)

                    loadingRequest.redirect = redirectRequest
                    loadingRequest.response = redirectResponse
                    loadingRequest.finishLoading()
                    return
                } catch let err {
                    loadingRequest.finishLoading(with: err)
                }
            }
            return
        }
        Logger.debug("handle loading \(customUrl)")
    }

    func bindHttpServer() {
        // 被拦下的字幕轨引用的空分片：合法 WebVTT、零 cue，让 AVKit 正常结束加载
        httpServer["/empty.vtt"] = { _ in
            HttpResponse.ok(.text("WEBVTT\n\n"))
        }
        httpServer["/subtitle"] = { [weak self] req in
            if let url = req.queryParams.first(where: { $0.0 == "u" })?.1 {
                let req = url.removingPercentEncoding ?? url
                if let content = self?.subtitleVTT(for: req) {
                    return HttpResponse.ok(.text(content))
                }
            }
            return HttpResponse.notFound()
        }
        // 只接受当前播放会话媒体标识的 /media/:id，不接受请求直接指定外部 URL，
        // 不将带签名的真实 CDN URL 编码到本地路径中。
        httpServer["/media/:id"] = { [weak self] req in
            guard let self else { return HttpResponse.internalServerError(nil) }
            return self.handleMediaProxyRequest(req)
        }
    }

    // MARK: - 本地媒体代理

    /// 解析 DASH segment_base.index_range（"start-end"），供信任锚点使用。
    static func indexRange(_ media: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> MediaByteRange? {
        let parts = media.segment_base.index_range.components(separatedBy: "-")
        guard parts.count == 2,
              let start = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(parts[1].trimmingCharacters(in: .whitespaces)),
              let range = try? MediaByteRange(start: start, end: end)
        else { return nil }
        return range
    }

    /// 为当前会话已注册的媒体流生成本地 URL；未注册/不可用时返回 nil（调用方回退直连）。
    func mediaTransportURL(for media: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> String? {
        guard transportMode != .direct, proxyAvailable, httpPort > 0 else { return nil }
        guard let id = proxyRegistry.id(for: media) else { return nil }
        return "http://127.0.0.1:\(httpPort)/media/\(id)"
    }

    func registerProxyMedia(aid: Int) {
        let referer = Keys.referer(for: aid)
        // 同一 DashMediaInfo 的多 CDN URL 共享同一媒体 ID；不同清晰度/codec/音视频轨道
        // 因 DashMediaInfo 不同而自然隔离，不会共用错误标识。
        var seen = Set<VideoPlayURLInfo.DashInfo.DashMediaInfo>()
        for entry in videoInfo {
            let media = entry.info
            guard seen.insert(media).inserted else { continue }
            let candidates = media.playableURLs
            guard !candidates.isEmpty else { continue }
            let mode: MediaTransportMode = transportMode == .accelerated ? .accelerated : .proxy
            let downloader = MediaRangeDownloader(candidates: candidates, referer: referer, mode: mode)
            proxyRegistry.register(media: media, candidates: candidates, referer: referer, downloader: downloader)
        }
    }

    /// Swifter 同步 handler（运行在后台连接队列，禁止阻塞主线程）。
    /// 响应头发送前完成元信息验证；206 发送后只允许补齐剩余字节或截断触发播放器级恢复。
    /// 注意：handler 只持有注册表的不可变元信息快照（锁内一次性拷贝），
    /// 不直接读取可变的 Entry，避免与 totalLength 更新竞争。
    func handleMediaProxyRequest(_ req: HttpRequest) -> HttpResponse {
        guard let mediaID = req.params[":id"], !mediaID.isEmpty else {
            return HttpResponse.badRequest(nil)
        }
        guard let entry = proxyRegistry.snapshot(for: mediaID) else {
            return HttpResponse.notFound(nil)
        }
        let method = req.method.uppercased()
        if method == "HEAD" {
            // 返回与当前可用元信息一致的头，不传 body
            let headers = MediaRangeResponseHeaders.head(totalLength: entry.totalLength)
            return HttpResponse.raw(200, "OK", headers, nil)
        }
        guard method == "GET" else {
            return HttpResponse.badRequest(nil)
        }
        let rangeHeader = req.headers["range"]
        let parsed = MediaRangeParsing.parse(header: rangeHeader, fileLength: entry.totalLength)
        switch parsed {
        case .missing:
            // 无 Range 的整文件请求：307 重定向回原 CDN，不伪造 206。
            // 注意：Swifter 的 movedTemporarily 实际发送 307；AVPlayer 是否保留
            // Range 语义跟随跳转仍需真机验证（见验收 P2）。
            if let fallback = entry.candidates.first, URL(string: fallback) != nil {
                return HttpResponse.movedTemporarily(fallback)
            }
            return HttpResponse.badRequest(nil)
        case .multiUnsupported:
            let headers = MediaRangeResponseHeaders.rangeNotSatisfiable(totalLength: entry.totalLength)
            return HttpResponse.raw(416, "Range Not Satisfiable", headers, nil)
        case .invalid:
            return HttpResponse.badRequest(nil)
        case let .unsatisfiable(total):
            let headers = MediaRangeResponseHeaders.rangeNotSatisfiable(totalLength: total ?? entry.totalLength)
            return HttpResponse.raw(416, "Range Not Satisfiable", headers, nil)
        case .openEnded, .suffix:
            // 需 total 归一化；未知 total 时走直连重定向降级，不阻塞等待探测
            if let total = entry.totalLength {
                let normalized = MediaRangeParsing.normalizeUnbounded(parsed, fileLength: total)
                if case let .single(range) = normalized {
                    return serveVerifiedRange(range, entry: entry, mediaID: mediaID)
                }
                let headers = MediaRangeResponseHeaders.rangeNotSatisfiable(totalLength: total)
                return HttpResponse.raw(416, "Range Not Satisfiable", headers, nil)
            }
            if let fallback = entry.candidates.first {
                return HttpResponse.movedTemporarily(fallback)
            }
            return HttpResponse.badRequest(nil)
        case let .single(range):
            // 超出安全容量的请求降级直连（与下载器共用同一个上限，避免清单放行而下载器拒收）
            if range.length > MediaDownloadLimits.singleRequestMemoryCap {
                if let fallback = entry.candidates.first {
                    return HttpResponse.movedTemporarily(fallback)
                }
                return HttpResponse.badRequest(nil)
            }
            return serveVerifiedRange(range, entry: entry, mediaID: mediaID)
        }
    }

    func serveVerifiedRange(_ range: MediaByteRange, entry: MediaProxyRegistry.MediaSnapshot, mediaID: String) -> HttpResponse {
        // 首次请求时 total 通常未知，按 RFC 以 * 声明；AVPlayer 在当前 HLS 链路
        // 是否接受 bytes start-end/* 仍需真机验证（见验收 P2）。后续请求复用已缓存的 total。
        let headers = MediaRangeResponseHeaders.partialContent(range: range, totalLength: entry.totalLength)
        let downloader = entry.downloader
        let candidates = entry.candidates
        weak var weakSelf = self
        return HttpResponse.raw(206, "Partial Content", headers) { writer in
            let pipe = MediaBytePipe()
            let streamTask = Task {
                await downloader.stream(range: range, to: pipe)
            }
            // 后台同步排空：不阻塞主线程或 URLSession 回调线程
            assert(!Thread.isMainThread, "media proxy writer must not run on main thread")
            do {
                while true {
                    let chunk: Data?
                    do {
                        chunk = try pipe.readSync(maxLength: 64 * 1024, timeout: 30)
                    } catch {
                        streamTask.cancel()
                        throw error
                    }
                    guard let chunk else { break }
                    do {
                        try writer.write(chunk)
                    } catch {
                        // 读取方关闭/超时/写入失败：立即取消生产者（幂等），截断连接
                        streamTask.cancel()
                        throw error
                    }
                }
            } catch {
                streamTask.cancel()
                // 206 已发送：不能改写状态码，只能截断；播放器级恢复由 BVideoPlayPlugin 触发
                throw error
            }
            // 成功交付后异步更新诊断与 total 缓存（不阻塞 writer）
            Task { [weakSelf, downloader, candidates, mediaID] in
                if let total = await downloader.knownTotal() {
                    weakSelf?.proxyRegistry.updateTotalLength(total, for: mediaID)
                }
                if let diag = await weakSelf?.buildAccelerationText(downloader: downloader) {
                    weakSelf?.updateAccelerationText(diag)
                }
                _ = candidates
            }
        }
    }

    func buildAccelerationText(downloader: MediaRangeDownloader) async -> String {
        let diag = await downloader.diagnostics()
        let modeText: String
        switch diag.transportMode {
        case .direct: modeText = "direct"
        case .proxy: modeText = "proxy"
        case .accelerated: modeText = "accel"
        }
        // 不输出 URL 查询参数/签名/Cookie；Mbps 为估计聚合值，仅供参考
        return String(format: "accel mode:%@ hosts:%d est %.1fMbps sub:%d fail:%d retry:%d ratio:%.2f%@",
                      modeText, diag.activeHosts, diag.estimatedAggregateMbps,
                      diag.activeSubrequests, diag.failures, diag.retries,
                      diag.redundancyRatio,
                      diag.downgradedToDirect ? " downgraded" : "")
    }
}
