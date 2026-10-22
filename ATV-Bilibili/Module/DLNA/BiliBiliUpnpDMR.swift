//
//  BiliBiliUpnpDMR.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/11/25.
//

import CocoaAsyncSocket
import CoreMedia
import Foundation
import Swifter
import UIKit

class BiliBiliUpnpDMR: NSObject {
    static let shared = BiliBiliUpnpDMR()

    private let ssdpHost = "239.255.255.250"
    private let ssdpPort: UInt16 = 1900
    private let httpPort: in_port_t = 9958
    private let mockServerName = "Linux/3.0.0, UPnP/1.0, Platinum/1.0.5.13"

    private let udpQueue = DispatchQueue(label: "com.bilibili.upnp.udp")

    weak var currentPlugin: BUpnpPlugin?

    private var udp: GCDAsyncUdpSocket!
    private var httpServer = HttpServer()
    @MainActor private var sessions = Set<NVASession>()
    private var started = false
    private var ip: String?
    private var boardcastTimer: Timer?

    /// 读取 bundle 内资源；缺失或读取失败只记日志并返回空串，避免启动即崩
    private static func loadBundleText(_ name: String) -> String {
        guard let file = Bundle.main.url(forResource: name, withExtension: "xml") else {
            Logger.warn("[DLNA] 缺少资源 \(name).xml")
            return ""
        }
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch {
            Logger.warn("[DLNA] 读取 \(name).xml 失败: \(error)")
            return ""
        }
    }

    private lazy var serverInfo: String = BiliBiliUpnpDMR.loadBundleText("DLNAInfo").replacingOccurrences(of: "{{UUID}}", with: bUuid)

    private lazy var nirvanaControl: String = BiliBiliUpnpDMR.loadBundleText("NirvanaControl")

    private lazy var avTransportScpd: String = BiliBiliUpnpDMR.loadBundleText("AvTransportScpd")

    private lazy var bUuid: String = {
        if Settings.uuid.count > 0 {
            return Settings.uuid
        }
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var randomString = ""
        for _ in 0..<35 {
            let rand = arc4random_uniform(36)
            let nextChar = letters[letters.index(letters.startIndex, offsetBy: Int(rand))]
            randomString.append(nextChar)
        }
        Settings.uuid = randomString
        return randomString
    }()

    override private init() { super.init() }
    func start() {
        // 延迟启动：SSDP 绑定/HTTP 端口监听让出冷启动首帧；已进后台则放弃
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard UIApplication.shared.applicationState == .active else { return }
            self?.startIfNeed()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

        httpServer["/description.xml"] = { [weak self] req in
            Logger.debug("handel serverInfo")
            return HttpResponse.ok(.text(self?.serverInfo ?? ""))
        }

        httpServer["/projection"] = nvasocket(uuid: bUuid, didConnect: { [weak self] session in
            Logger.info("session connected \(session)")
            Task { @MainActor in self?.sessions.insert(session) }
        }, didDisconnect: { [weak self] session in
            Logger.info("session disconnect \(session)")
            Task { @MainActor in self?.sessions.remove(session) }
        }, processor: { [weak self] session, frame in
            Task { @MainActor in self?.handleEvent(frame: frame, session: session) }
        })

        httpServer["/dlna/NirvanaControl.xml"] = {
            [weak self] req in
            Logger.debug("handle NirvanaControl")
            let txt = self?.nirvanaControl ?? ""
            return HttpResponse.ok(.text(txt))
        }

        httpServer.get["/dlna/AVTransport.xml"] = {
            [weak self] req in
            Logger.debug("handle AVTransport.xml")
            let txt = self?.avTransportScpd ?? ""
            return HttpResponse.ok(.text(txt))
        }

        httpServer.post["/AVTransport/action"] = {
            req in
            let str = String(data: Data(req.body), encoding: .utf8) ?? ""
            Logger.debug("handle AVTransport.xml \(str)")
            return HttpResponse.ok(.text(str))
        }

        httpServer["/AVTransport/event"] = {
            req in
            return HttpResponse.internalServerError(nil)
        }

        #if DEBUG
            // 调试日志只允许本地 Debug 构建读取；Release 的 9958 端口只保留投屏协议，
            // 避免同一局域网内任意设备读到视频标题/账号诊断信息。
            httpServer["/debug/log"] = {
                req in
                if let path = Logger.latestLogPath(),
                   let str = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
                {
                    return HttpResponse.ok(.text(str))
                }
                return HttpResponse.internalServerError(nil)
            }
        #endif
    }

    func stop() {
        boardcastTimer?.invalidate()
        boardcastTimer = nil
        udp?.close()
        httpServer.stop()
        started = false
        Logger.info("dmr stopped")
    }

    @objc func didEnterBackground() {
        stop()
    }

    @objc func willEnterForeground() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.startIfNeed()
        }
    }

    private func startIfNeed() {
        stop()
        guard Settings.enableDLNA else { return }
        ip = getIPAddress()
        do {
            udp = GCDAsyncUdpSocket(delegate: self, delegateQueue: udpQueue)
            try udp.enableBroadcast(true)
            try udp.enableReusePort(true)
            try udp.bind(toPort: ssdpPort)
            try udp.joinMulticastGroup(ssdpHost)
            try udp.beginReceiving()
            try httpServer.start(httpPort)
            started = true
            Logger.info("dmr started, http: \(httpPort), ssdp: \(ssdpPort)")
        } catch let err {
            started = false
            udp?.close()
            udp = nil
            httpServer.stop()
            Logger.warn("dmr start fail: \(err.localizedDescription).")
            return
        }
        // SSDP NOTIFY 心跳 30s：发现主要靠控制器主动 M-SEARCH(本类有响应处理)，
        // 常驻 1s 广播整个 App 生命周期每秒唤醒一次纯属浪费
        boardcastTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            guard started else { return }
            guard let notify = getSSDPNotify(),
                  let data = notify.data(using: .utf8)
            else { return }
            udp.send(data, toHost: ssdpHost, port: ssdpPort, withTimeout: 1, tag: 0)
        }
    }

    private func getIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { return "" }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" || name == "en2" || name == "en3" || name == "en4" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                        if name == "en0" {
                            break
                        }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    private func getSSDPResp() -> String {
        guard let ip = ip ?? getIPAddress() else {
            Logger.debug("no ip")
            return ""
        }

        return """
        HTTP/1.1 200 OK
        LOCATION: http://\(ip):\(httpPort)/description.xml
        CACHE-CONTROL: max-age=30
        SERVER: \(mockServerName)
        EXT:
        BOOTID.UPNP.ORG: 1669443520
        CONFIGID.UPNP.ORG: 10177363
        USN: uuid:atvbilibili&\(bUuid)::upnp:rootdevice
        ST: upnp:rootdevice
        DATE: \(ssdpDateString())

        """
    }

    private func getSSDPNotify() -> String? {
        guard let ip = ip ?? getIPAddress() else {
            Logger.debug("no ip")
            return nil
        }
        let text = """
        NOTIFY * HTTP/1.1
        Host: \(ssdpHost):\(ssdpPort)
        Location: http://\(ip):9958/description.xml
        Cache-Control: max-age=30
        Server: \(mockServerName)
        NTS: ssdp:alive
        USN: uuid:\(bUuid)::urn:schemas-upnp-org:device:MediaRenderer:1
        NT: urn:schemas-upnp-org:device:MediaRenderer:1

        """
        return text
    }

    private func ssdpDateString() -> String {
        DateFormatter.httpDate.string(from: Date())
    }

    func handleEvent(frame: NVASession.NVAFrame, session: NVASession) {
        let topMost = UIViewController.topMostViewController()
        switch frame.action {
        case "GetVolume":
            session.sendReply(content: ["volume": 30])
        case "Play":
            handlePlay(info: parseJSON(frame.body))
            session.sendEmpty()
        case "Pause":
            currentPlugin?.pause()
            session.sendEmpty()
        case "Resume":
            currentPlugin?.resume()
            session.sendEmpty()
        case "SwitchDanmaku":
            let info = parseJSON(frame.body)
            Defaults.shared.setShowDanmaku(jsonBool(info, "open"))
            session.sendEmpty()
        case "Seek":
            let info = parseJSON(frame.body)
            currentPlugin?.seek(to: jsonDouble(info, "seekTs"))
            session.sendEmpty()
        case "Stop":
            (topMost as? CommonPlayerViewController)?.dismiss(animated: true)
            session.sendEmpty()
        case "PlayUrl":
            let info = parseJSON(frame.body)
            session.sendEmpty()
            guard let url = jsonURL(info, "url"),
                  let extStr = URLComponents(string: url.absoluteString)?.queryItems?
                  .first(where: { $0.name == "nva_ext" })?.value
            else {
                Logger.warn("get play url: \(frame.body)")
                return
            }
            handlePlay(info: jsonDict(parseJSON(extStr), "content"))
        default:
            Logger.debug("action: \(frame.action)")
            session.sendEmpty()
        }
    }

    // MARK: - NVA 报文解析（投屏端字段类型不稳定，统一做宽松取值）

    private func parseJSON(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [:] }
        return object as? [String: Any] ?? [:]
    }

    private func jsonInt(_ json: [String: Any], _ key: String) -> Int {
        switch json[key] {
        case let value as Int: return value
        case let value as Double: return Int(value)
        case let value as String: return Int(value) ?? 0
        default: return 0
        }
    }

    private func jsonDouble(_ json: [String: Any], _ key: String) -> Double {
        switch json[key] {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as String: return Double(value) ?? 0
        default: return 0
        }
    }

    private func jsonBool(_ json: [String: Any], _ key: String) -> Bool {
        switch json[key] {
        case let value as Bool: return value
        case let value as Int: return value != 0
        case let value as String: return (Int(value) ?? 0) != 0
        default: return false
        }
    }

    private func jsonURL(_ json: [String: Any], _ key: String) -> URL? {
        guard let value = json[key] as? String else { return nil }
        return URL(string: value)
    }

    private func jsonDict(_ json: [String: Any], _ key: String) -> [String: Any] {
        json[key] as? [String: Any] ?? [:]
    }

    func handlePlay(info: [String: Any]) {
        // 直播功能已移除，收到直播房间的投屏请求时直接忽略
        let roomId = jsonInt(info, "roomId")
        if roomId > 0 {
            Logger.warn("忽略直播房间投屏请求: room \(roomId)")
            return
        }
        playVideo(info: info)
    }

    enum PlayStatus: Int {
        case loading = 3
        case playing = 4
        case paused = 5
        case end = 6
        case stop = 7
    }

    @MainActor func sendStatus(status: PlayStatus) {
        Logger.debug("send status: \(status)")
        Array(sessions).forEach { $0.sendCommand(action: "OnPlayState", content: ["playState": status.rawValue]) }
    }

    @MainActor func sendProgress(duration: Int, current: Int) {
        Array(sessions).forEach { $0.sendCommand(action: "OnProgress", content: ["duration": duration, "position": current]) }
    }
}

extension BiliBiliUpnpDMR {
    func playVideo(info: [String: Any]) {
        let aid = jsonInt(info, "aid")
        let cid = jsonInt(info, "cid")
        let epid = jsonInt(info, "epid")

        let player: VideoDetailViewController
        if epid > 0 {
            player = VideoDetailViewController.create(epid: epid)
        } else {
            player = VideoDetailViewController.create(aid: aid, cid: cid)
        }
        guard let root = AppDelegate.shared.mainWindow?.rootViewController else {
            Logger.warn("[dlna] 收到投屏 Play，但当前没有可用窗口，已忽略")
            return
        }
        let topMost = root.topMostViewController()
        if root.presentedViewController != nil {
            root.dismiss(animated: false) {
                player.present(from: root.topMostViewController(), directlyEnterVideo: true)
            }
        } else {
            player.present(from: topMost, directlyEnterVideo: true)
        }
    }
}

extension BiliBiliUpnpDMR: GCDAsyncUdpSocketDelegate {
    func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        address.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            let sockaddrPtr = pointer.bindMemory(to: sockaddr.self)
            guard let unsafePtr = sockaddrPtr.baseAddress else { return }
            guard getnameinfo(unsafePtr, socklen_t(address.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 else {
                return
            }
        }
        var ipAddress = String(cString: hostname)
        ipAddress = ipAddress.replacingOccurrences(of: "::ffff:", with: "")
        let str = String(data: data, encoding: .utf8)
        if str?.contains("ssdp:discover") == true {
            let data = getSSDPResp().data(using: .utf8)!
            sock.send(data, toAddress: address, withTimeout: -1, tag: 0)
        }
    }
}
