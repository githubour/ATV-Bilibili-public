//
//  LoginViewController.swift
//  ATV-Bilibili
//
//  Created by Etan Chen on 2021/3/28.
//

import Alamofire
import Foundation
import SnapKit
import UIKit

class LoginViewController: UIViewController {
    private let ciContext = CIContext()

    private let qrcodeImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private let regenerateButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = "重新生成二维码"
        config.contentInsets = NSDirectionalEdgeInsets(top: 20, leading: 40, bottom: 20, trailing: 40)

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    /// 从「我的 → 账号切换 → 添加账号」进入时提供返回入口；作为根登录页时为空
    var onCancel: (() -> Void)?

    private lazy var cancelButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = "返回"
        config.image = UIImage(systemName: "chevron.left")
        config.imagePadding = 8
        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(actionCancel), for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()

    private let leftContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let dividerView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor(white: 0.3333333333, alpha: 1)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "账号登录"
        label.font = UIFont.preferredFont(forTextStyle: .title1)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let guideLabel: UILabel = {
        let label = UILabel()
        label.text = "1 请打开BiliBili官方手机客户端扫码登录\n\n2. 如果登录失败尝试点击重新生成二维码"
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.numberOfLines = 0
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private static let guideText = "1 请打开BiliBili官方手机客户端扫码登录\n\n2. 如果登录失败尝试点击重新生成二维码"

    private static let pollInterval: Duration = .seconds(4)
    private static let maxPollCount = 200

    private var pollingTask: Task<Void, Never>?
    private var oauthKey: String = ""

    static func create() -> LoginViewController {
        LoginViewController()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        cancelButton.isHidden = (onCancel == nil)
    }

    @objc private func actionCancel() {
        onCancel?()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        initValidation()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        qrcodeImageView.image = nil
        stopValidation()
    }

    func generateQRCode(from string: String) -> UIImage? {
        guard
            let data = string.data(using: .ascii),
            let filter = CIFilter(name: "CIQRCodeGenerator")
        else {
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let extent = outputImage.extent.integral
        guard !extent.isEmpty else { return nil }

        let targetSize: CGFloat = 540
        let scale = max(1, floor(targetSize / max(extent.width, extent.height)))
        let width = Int(extent.width * scale)
        let height = Int(extent.height * scale)

        guard
            let cgImage = ciContext.createCGImage(outputImage, from: extent),
            let bitmapContext = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else {
            return nil
        }

        bitmapContext.interpolationQuality = .none
        bitmapContext.scaleBy(x: scale, y: scale)
        bitmapContext.draw(cgImage, in: extent)

        guard let scaledImage = bitmapContext.makeImage() else { return nil }
        return UIImage(cgImage: scaledImage)
    }

    func initValidation() {
        stopValidation()
        qrcodeImageView.image = nil
        guideLabel.textColor = .label
        guideLabel.text = Self.guideText
        Task { [weak self] in
            guard let self else { return }
            do {
                let qr = try await ApiRequest.requestLoginQR()
                guard !Task.isCancelled else { return }
                self.qrcodeImageView.image = self.generateQRCode(from: qr.url)
                self.oauthKey = qr.authCode
                self.startValidation()
            } catch {
                guard !Task.isCancelled else { return }
                Logger.warn("[login] 获取登录二维码失败: \(error)")
                // 旧实现只写日志，界面停在空白二维码区；这里给可见错误与可聚焦的重试按钮。
                self.guideLabel.textColor = .systemOrange
                self.guideLabel.text = "二维码获取失败：\(error.localizedDescription)\n\n检查网络后点击「重新生成二维码」重试。"
                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
            }
        }
    }

    private func startValidation() {
        pollingTask = Task { [weak self] in
            for _ in 0..<LoginViewController.maxPollCount {
                guard let self, !Task.isCancelled else { return }
                try? await Task.sleep(for: LoginViewController.pollInterval)
                guard !Task.isCancelled else { return }
                if await self.loopValidation() {
                    return
                }
            }
        }
    }

    private func stopValidation() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func didValidationSuccess() {
        qrcodeImageView.image = nil
        stopValidation()
        if presentingViewController != nil {
            dismiss(animated: false) {
                AppDelegate.shared.showTabBar()
            }
        } else {
            AppDelegate.shared.showTabBar()
        }
    }

    /// 返回 true 表示登录流程已结束（成功或二维码已重新生成）
    @MainActor
    private func loopValidation() async -> Bool {
        let state = await ApiRequest.verifyLoginQR(code: oauthKey)
        switch state {
        case .expire:
            initValidation()
            return true
        case .waiting, .fail:
            return false
        case let .success(token, cookies):
            await AccountManager.shared.registerAccount(token: token, cookies: cookies)
            didValidationSuccess()
            return true
        }
    }

    @objc private func actionStart() {
        initValidation()
    }

    private func setupUI() {
        view.backgroundColor = .black

        view.addSubview(leftContainerView)
        view.addSubview(dividerView)
        view.addSubview(titleLabel)
        view.addSubview(guideLabel)
        view.addSubview(cancelButton)

        cancelButton.snp.makeConstraints { make in
            make.leading.equalTo(view.safeAreaLayoutGuide).offset(60)
            make.top.equalTo(view.safeAreaLayoutGuide).offset(40)
        }

        let qrStackView = UIStackView(arrangedSubviews: [qrcodeImageView, regenerateButton])
        qrStackView.axis = .vertical
        qrStackView.alignment = .center
        qrStackView.spacing = 50
        qrStackView.translatesAutoresizingMaskIntoConstraints = false
        leftContainerView.addSubview(qrStackView)

        regenerateButton.addTarget(self, action: #selector(actionStart), for: .primaryActionTriggered)

        leftContainerView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.bottom.equalToSuperview()
            make.width.equalToSuperview().multipliedBy(0.5)
        }

        qrStackView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        qrcodeImageView.snp.makeConstraints { make in
            make.width.height.equalTo(540)
        }

        dividerView.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.bottom.equalTo(view.safeAreaLayoutGuide)
            make.width.equalTo(2)
        }

        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(dividerView.snp.trailing).offset(100)
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(120)
        }

        guideLabel.snp.makeConstraints { make in
            make.leading.equalTo(dividerView.snp.trailing).offset(100)
            make.top.equalTo(titleLabel.snp.bottom).offset(50)
            make.trailing.lessThanOrEqualTo(view.safeAreaLayoutGuide.snp.trailing).offset(-100)
        }
    }
}
