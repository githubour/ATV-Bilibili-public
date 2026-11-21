//
//  ReplyImageViewerController.swift
//  ATV-Bilibili
//
//  评论图片全屏查看：多图用「上一张/下一张」左右切换，较大降采样加载，
//  不回退到未降采样的原图（项目优化报告 §3.7：原图动辄 6~10MB）。
//

import Kingfisher
import SnapKit
import UIKit

final class ReplyImageViewerController: UIViewController {
    private let imageURLStrings: [String]
    private var currentIndex = 0

    private let imageView = UIImageView()
    private let pageLabel = UILabel()
    private let prevButton = BLCustomTextButton()
    private let closeButton = BLCustomTextButton()
    private let nextButton = BLCustomTextButton()

    init(imageURLStrings: [String]) {
        self.imageURLStrings = imageURLStrings
        super.init(nibName: nil, bundle: nil)
        // 同 ContentDetailViewController：卡片式浮层 + 短促渐隐，底下页面仍透出一点
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [closeButton] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.92)

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        view.addSubview(imageView)
        imageView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide).inset(
                UIEdgeInsets(top: 40, left: 40, bottom: 150, right: 40)
            )
        }

        pageLabel.font = .systemFont(ofSize: 26, weight: .medium)
        pageLabel.textColor = .secondaryLabel
        pageLabel.textAlignment = .center
        view.addSubview(pageLabel)
        pageLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-108)
        }

        prevButton.title = "上一张"
        closeButton.title = "关闭"
        nextButton.title = "下一张"
        prevButton.onPrimaryAction = { [weak self] _ in self?.step(-1) }
        nextButton.onPrimaryAction = { [weak self] _ in self?.step(1) }
        closeButton.onPrimaryAction = { [weak self] _ in self?.dismiss(animated: true) }

        let arranged: [UIView] = imageURLStrings.count > 1
            ? [prevButton, closeButton, nextButton]
            : [closeButton]
        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .horizontal
        stack.spacing = 40
        stack.alignment = .center
        view.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-30)
        }

        showImage(at: 0)
    }

    private func step(_ delta: Int) {
        guard imageURLStrings.count > 1 else { return }
        let count = imageURLStrings.count
        showImage(at: (currentIndex + delta + count) % count)
    }

    private func showImage(at index: Int) {
        guard imageURLStrings.indices.contains(index) else { return }
        currentIndex = index
        if let url = URL(string: imageURLStrings[index]) {
            imageView.kf.setImage(
                with: url,
                options: [.processor(DownsamplingImageProcessor(size: CGSize(width: 2000, height: 2000)))]
            )
        }
        pageLabel.text = imageURLStrings.count > 1 ? "\(index + 1) / \(imageURLStrings.count)" : nil
    }
}
