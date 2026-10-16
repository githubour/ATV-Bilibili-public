//
//  BUpnpPlugin.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2024/5/25.
//

import AVFoundation
import Foundation

class BUpnpPlugin: NSObject, CommonPlayerPlugin {
    let duration: Int?
    weak var player: AVPlayer?
    private var observar: Any?

    init(duration: Int?) {
        self.duration = duration
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        player?.play()
    }

    func seek(to time: TimeInterval) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func playerWillStart(player: AVPlayer) {
        BiliBiliUpnpDMR.shared.currentPlugin = self
        self.player = player
        guard let duration else { return }
        observar = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { time in
            MainActor.assumeIsolated {
                BiliBiliUpnpDMR.shared.sendProgress(duration: duration, current: Int(time.seconds))
            }
        }
    }

    func playerDidStart(player: AVPlayer) {
        sendStatus(.playing)
    }

    func playerDidPause(player: AVPlayer) {
        sendStatus(.paused)
    }

    func playerDidEnd(player: AVPlayer) {
        sendStatus(.end)
    }

    func playerDidFail(player: AVPlayer) {
        sendStatus(.stop)
    }

    func playerDidCleanUp(player: AVPlayer) {
        if let observar {
            player.removeTimeObserver(observar)
        }
        observar = nil
        sendStatus(.stop)
    }

    private func sendStatus(_ status: BiliBiliUpnpDMR.PlayStatus) {
        Task { @MainActor in
            BiliBiliUpnpDMR.shared.sendStatus(status: status)
        }
    }
}
