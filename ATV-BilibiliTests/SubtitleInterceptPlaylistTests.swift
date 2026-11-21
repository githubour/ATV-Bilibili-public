//
//  SubtitleInterceptPlaylistTests.swift
//  ATV-BilibiliTests
//

@testable import ATV_Bilibili
import XCTest

/// AVKit 自动请求未选中的 ai-zh 字幕清单时，零分片清单会触发每秒上千次重试。
/// 拦截分支必须回一个带空 WebVTT 分片的合法 VOD，系统才会停止重试。
final class SubtitleInterceptPlaylistTests: XCTestCase {
    func test_interceptedPlaylistIsParsableEmptyVOD() {
        let delegate = BilibiliVideoResourceLoaderDelegate()
        delegate.httpPort = 51234

        let playlist = delegate.emptySubtitlePlaylistForIntercept()
        let lines = playlist.split(whereSeparator: \.isNewline).map(String.init)

        XCTAssertEqual(lines.first, "#EXTM3U")
        XCTAssertTrue(lines.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(lines.contains("#EXTINF:1.0,"))
        XCTAssertTrue(lines.contains("http://127.0.0.1:51234/empty.vtt"))
        XCTAssertTrue(lines.contains("#EXT-X-ENDLIST"))
    }

    func test_interceptedPlaylistFallsBackWithoutLocalServer() {
        let delegate = BilibiliVideoResourceLoaderDelegate()
        delegate.httpPort = 0

        XCTAssertEqual(
            delegate.emptySubtitlePlaylistForIntercept(),
            BilibiliVideoResourceLoaderDelegate.emptySubtitlePlaylist
        )
    }
}
