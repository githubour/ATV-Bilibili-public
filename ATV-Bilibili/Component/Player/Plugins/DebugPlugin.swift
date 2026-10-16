//
//  DebugPlugin.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2024/5/25.
//

import AVKit
import UIKit

class DebugPlugin: NSObject, CommonPlayerPlugin {
    private var debugView: UILabel?
    private weak var containerView: UIView?
    private var debugTimer: Timer?
    private weak var player: AVPlayer?
    private var debugEnable: Bool { debugTimer?.isValid ?? false }

    var additionDebugInfo: (() -> String)?

    func addViewToPlayerOverlay(container: UIView) {
        containerView = container
    }

    func playerDidChange(player: AVPlayer) {
        self.player = player
    }

    /// debugView 是开 Debug 时才懒加载加到 overlay 的，插件被换掉后必须自己摘掉，
    /// 否则会永久留在浮层上显示过期数据（stopDebug 只是隐藏，不移除）
    func playerWillCleanUp(playerVC: AVPlayerViewController) {
        stopDebug()
        debugView?.removeFromSuperview()
        debugView = nil
        containerView = nil
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        let debugEnableImage = UIImage(systemName: "terminal.fill")
        let debugDisableImage = UIImage(systemName: "terminal")
        let debugAction = UIAction(title: "Debug", image: debugEnable ? debugEnableImage : debugDisableImage) {
            [weak self] action in
            guard let self = self else { return }
            if self.debugEnable {
                self.stopDebug()
                action.image = debugDisableImage
            } else {
                action.image = debugEnableImage
                self.startDebug()
            }
        }
        return insertIntoMenu([debugAction], menu: .moreMenu, current: &current, fallbackToTopLevel: true)
    }

    deinit {
        debugTimer?.invalidate()
    }

    private func startDebug() {
        if debugView == nil {
            debugView = UILabel()
            debugView?.backgroundColor = UIColor.black.withAlphaComponent(0.8)
            debugView?.textColor = UIColor.white
            containerView?.addSubview(debugView!)
            debugView?.numberOfLines = 0
            debugView?.font = UIFont.systemFont(ofSize: 26)
            debugView?.snp.makeConstraints { make in
                make.top.equalToSuperview().offset(12)
                make.right.equalToSuperview().offset(-12)
                make.width.equalTo(800)
            }
        }
        debugView?.isHidden = false
        debugTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let info = self?.fetchDebugInfo()
            self?.debugView?.text = info
        }
    }

    private func stopDebug() {
        debugTimer?.invalidate()
        debugTimer = nil
        debugView?.isHidden = true
    }

    private func fetchDebugInfo() -> String {
        let bitrateStr: (Double) -> String = {
            bit in
            String(format: "%.2fMbps", bit / 1024.0 / 1024.0)
        }
        guard let player else { return "Player no init" }

        var logs = """
        time control status: \(player.timeControlStatus.rawValue) \(player.reasonForWaitingToPlay?.rawValue ?? "")
        player status:\(player.status.rawValue)
        """

        guard let log = player.currentItem?.accessLog() else { return logs }
        guard let item = log.events.last else { return logs }
        // 完整 uri 有几百字符，会把浮层其他信息挤掉，只显示 host（完整地址在日志里）
        let host = URLComponents(string: item.uri ?? "")?.host ?? "-"
        let addr = item.serverAddress ?? ""
        let changes = item.numberOfServerAddressChanges
        let dropped = item.numberOfDroppedVideoFrames
        let stalls = item.numberOfStalls
        let averageAudioBitrate = item.averageAudioBitrate
        let averageVideoBitrate = item.averageVideoBitrate
        let indicatedBitrate = item.indicatedBitrate
        let observedBitrate = item.observedBitrate
        logs += """
        host:\(host), ip:\(addr), change:\(changes)
        drop:\(dropped) stalls:\(stalls)
        bitrate audio:\(bitrateStr(averageAudioBitrate)), video: \(bitrateStr(averageVideoBitrate))
        observedBitrate:\(bitrateStr(observedBitrate))
        indicatedAverageBitrate:\(bitrateStr(indicatedBitrate))
        """

        if let additionDebugInfo = additionDebugInfo?(), !additionDebugInfo.isEmpty {
            logs = additionDebugInfo + "\n" + logs
        }
        return logs
    }
}
