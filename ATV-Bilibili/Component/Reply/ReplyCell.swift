//
// Created by Yam on 2024/6/9.
//

import Kingfisher
import SnapKit
import UIKit

/// 玻璃底材的评论卡容器：圆角在自身 layoutSubviews 里按当前高度计算，
/// 不依赖外层 cell 首次布局时序（见 BLCapsuleView.swift 头注释的坑）
fileprivate final class ReplyGlassBackgroundView: UIVisualEffectView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = BLCardCornerRadius.value(forHeight: bounds.height)
        layer.cornerCurve = .continuous
    }
}

final class ReplyCell: BLMotionCollectionViewCell {
    private let containerView = ReplyGlassBackgroundView(effect: BLGlass.effect())
    private let avatarImageView = UIImageView()
    private let userNameLabel = UILabel()
    private let likeIconView = UIImageView(image: UIImage(systemName: "heart.fill"))
    private let metaLabel = UILabel()
    private let contenLabel = UILabel()

    /// 0 = 不限行数（楼中楼页）；详情页紧凑卡设 3，配合 430×270 的卡片尺寸
    var maxContentLines = 0 {
        didSet { contenLabel.numberOfLines = maxContentLines }
    }

    /// 楼中楼页全宽单列用：把内容 label 底部改为等高约束，贯通竖向约束链以撑开自适应高度。
    /// 详情页 430×270 固定卡保持 `<=`，不受影响。
    var selfSizingContent = false {
        didSet {
            guard selfSizingContent != oldValue else { return }
            updateContentConstraints()
        }
    }

    override func setup() {
        super.setup()
        // 焦点放大刻意收小：评论卡行距只有 10pt，基类 1.1 倍的下缘会压进下一行 18pt，
        // tvOS 26+ 焦点引擎按变换后几何找下一项，纵向候选与聚焦卡重叠时会拒移动；
        // 1.03 倍下缘只探出 5.4pt，选中感靠玻璃底材的系统焦点效果 + 倾斜视差补足
        scaleFactor = 1.03
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        containerView.clipsToBounds = true
        contentView.addSubview(containerView)
        containerView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.layer.cornerRadius = 25

        userNameLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        userNameLabel.textColor = .secondaryLabel
        userNameLabel.lineBreakMode = .byTruncatingTail
        userNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        likeIconView.tintColor = .secondaryLabel
        likeIconView.contentMode = .scaleAspectFit

        metaLabel.font = .systemFont(ofSize: 22)
        metaLabel.textColor = .secondaryLabel
        metaLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        contenLabel.font = .systemFont(ofSize: 28)
        contenLabel.textColor = .label
        contenLabel.numberOfLines = 0
        contenLabel.lineBreakMode = .byTruncatingTail

        let metaStack = UIStackView(arrangedSubviews: [likeIconView, metaLabel])
        metaStack.axis = .horizontal
        metaStack.spacing = 6
        metaStack.alignment = .center

        let container = containerView.contentView
        container.addSubview(avatarImageView)
        container.addSubview(userNameLabel)
        container.addSubview(metaStack)
        container.addSubview(contenLabel)

        avatarImageView.snp.makeConstraints { make in
            make.leading.top.equalToSuperview().offset(36)
            make.size.equalTo(50)
        }
        likeIconView.snp.makeConstraints { make in
            make.size.equalTo(18)
        }
        metaStack.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-36)
            make.centerY.equalTo(avatarImageView)
        }
        userNameLabel.snp.makeConstraints { make in
            make.leading.equalTo(avatarImageView.snp.trailing).offset(16)
            make.centerY.equalTo(avatarImageView)
            make.trailing.lessThanOrEqualTo(metaStack.snp.leading).offset(-12)
        }
        updateContentConstraints()
    }

    private func updateContentConstraints() {
        contenLabel.snp.remakeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(36)
            make.top.equalTo(avatarImageView.snp.bottom).offset(20)
            if selfSizingContent {
                // 内容顶住垂直压缩，底边用 required 等式贯通约束链：
                // systemLayoutSizeFitting 才能算出完整内容高度、把 cell 撑到文字末尾。
                // 底边若是 <= / .high，高度会停在约三行的折中值，长文仍被省略号截断
                contenLabel.setContentCompressionResistancePriority(.required, for: .vertical)
                make.bottom.equalToSuperview().offset(-32)
            } else {
                contenLabel.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
                make.bottom.lessThanOrEqualToSuperview().offset(-32)
            }
        }
    }

    func config(replay: Replys.Reply) {
        avatarImageView.kf.setImage(
            with: URL(string: replay.member.avatar),
            options: .avatar
        )
        userNameLabel.text = replay.member.uname
        if let attr = replay.createAttributedString(displayView: contenLabel) {
            // 富文本统一补语义前景色，保证深色玻璃底上的可读性
            let styled = NSMutableAttributedString(attributedString: attr)
            styled.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: styled.length))
            contenLabel.attributedText = styled
        } else {
            contenLabel.text = replay.content.message
        }

        let likeCount = replay.like ?? 0
        var metaParts = [String]()
        if likeCount > 0 {
            metaParts.append("\(likeCount)")
        }
        if let time = DateFormatter.relativeTimeStringFor(timestamp: replay.ctime) {
            metaParts.append(time)
        }
        likeIconView.isHidden = likeCount <= 0
        metaLabel.text = metaParts.joined(separator: " · ")
    }
}

// MARK: - 主评论卡（楼中楼页 section 0）

/// 楼中楼页的主评论：自适应高度、完整显示不裁切。
/// 图片按真实宽高比纵向逐张排列、超长图限高，操作行的「查看大图」点开全屏看图页。
/// 宽高比以 Kingfisher 加载后的真实尺寸为准；接口给的 img_width/img_height 只用于减少首屏跳动。
final class MainReplyCell: BLMotionCollectionViewCell {
    struct JumpItem {
        let title: String
        let bvid: String
    }

    private static let inset: CGFloat = 40
    private static let imageMaxHeight: CGFloat = 720
    private static let placeholderRatio: CGFloat = 16.0 / 9.0
    private static let imageProcessorSize = CGSize(width: 1600, height: 1600)

    private let containerView = ReplyGlassBackgroundView(effect: BLGlass.effect())
    private let avatarImageView = UIImageView()
    private let userNameLabel = UILabel()
    private let likeIconView = UIImageView(image: UIImage(systemName: "heart.fill"))
    private let metaLabel = UILabel()
    private let contentLabel = UILabel()
    private let headerStack = UIStackView()
    private let imageStackView = UIStackView()
    private let actionStackView = UIStackView()
    private let rootStack = UIStackView()

    private var imageURLStrings: [String] = []
    private var appliedRatios: [CGFloat] = []
    private var pendingImageLoads = 0
    private var configGeneration = 0

    var onJump: ((String) -> Void)?
    var onOpenImages: (([String]) -> Void)?
    /// 所有图片的真实宽高比确定后回调一次，供 VC 触发 collectionView 重算高度
    var onImageAspectsResolved: (() -> Void)?

    override func setup() {
        super.setup()
        scaleFactor = 1.03
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        containerView.clipsToBounds = true
        contentView.addSubview(containerView)
        containerView.snp.makeConstraints { $0.edges.equalToSuperview() }

        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.layer.cornerRadius = 25
        avatarImageView.snp.makeConstraints { $0.size.equalTo(50) }

        userNameLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        userNameLabel.textColor = .secondaryLabel
        userNameLabel.lineBreakMode = .byTruncatingTail
        userNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        likeIconView.tintColor = .secondaryLabel
        likeIconView.contentMode = .scaleAspectFit
        likeIconView.snp.makeConstraints { $0.size.equalTo(20) }

        metaLabel.font = .systemFont(ofSize: 24)
        metaLabel.textColor = .secondaryLabel
        metaLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        contentLabel.font = .systemFont(ofSize: 32)
        contentLabel.textColor = .label
        contentLabel.numberOfLines = 0
        contentLabel.lineBreakMode = .byTruncatingTail
        // 长文/长图共存时 UIStackView 会优先压缩 label，撑不住就变省略号；顶住垂直压缩
        contentLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let metaStack = UIStackView(arrangedSubviews: [likeIconView, metaLabel])
        metaStack.axis = .horizontal
        metaStack.spacing = 6
        metaStack.alignment = .center

        headerStack.axis = .horizontal
        headerStack.spacing = 16
        headerStack.alignment = .center
        headerStack.addArrangedSubview(avatarImageView)
        headerStack.addArrangedSubview(userNameLabel)
        headerStack.addArrangedSubview(metaStack)

        imageStackView.axis = .vertical
        imageStackView.spacing = 16
        imageStackView.alignment = .center

        actionStackView.axis = .horizontal
        actionStackView.spacing = 20
        actionStackView.alignment = .leading

        rootStack.axis = .vertical
        rootStack.spacing = 24
        rootStack.addArrangedSubview(headerStack)
        // 操作行放在头部下方：长图会把 cell 撑到远超一屏，按钮留在底部时既容易被裁，
        // 焦点回到主评论也只滚到 cell 底部、看不到头像。靠上放让入口始终可见可聚焦
        rootStack.addArrangedSubview(actionStackView)
        rootStack.addArrangedSubview(contentLabel)
        rootStack.addArrangedSubview(imageStackView)

        containerView.contentView.addSubview(rootStack)
        // 四边 required 等式贯通约束链，配合 contentLabel 的 .required 垂直抗压，
        // 让 cell 高度随文字/图片完整撑开（AISummaryPlugin.SummaryCell 同款写法）
        rootStack.snp.makeConstraints { $0.edges.equalToSuperview().inset(Self.inset) }
    }

    /// cell 被聚焦时把焦点交给操作行按钮：tvOS 默认停在 cell 本身，
    /// 卡内的「查看大图 / 跳转」否则选不中
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard !actionStackView.isHidden, !actionStackView.arrangedSubviews.isEmpty else { return [] }
        return actionStackView.arrangedSubviews.map { $0 as UIFocusEnvironment }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configGeneration += 1
        clearImages()
        actionStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        avatarImageView.kf.cancelDownloadTask()
        imageURLStrings.removeAll()
        appliedRatios.removeAll()
        pendingImageLoads = 0
        onJump = nil
        onOpenImages = nil
        onImageAspectsResolved = nil
        contentLabel.attributedText = nil
        contentLabel.text = nil
    }

    func config(reply: Replys.Reply, jumpItems: [JumpItem]) {
        configGeneration += 1
        avatarImageView.kf.setImage(with: URL(string: reply.member.avatar), options: .avatar)
        userNameLabel.text = reply.member.uname
        if let attr = reply.createAttributedString(displayView: contentLabel) {
            let styled = NSMutableAttributedString(attributedString: attr)
            styled.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: styled.length))
            contentLabel.attributedText = styled
        } else {
            contentLabel.text = reply.content.message
        }

        let likeCount = reply.like ?? 0
        var metaParts = [String]()
        if likeCount > 0 { metaParts.append("\(likeCount)") }
        if let time = DateFormatter.relativeTimeStringFor(timestamp: reply.ctime) { metaParts.append(time) }
        likeIconView.isHidden = likeCount <= 0
        metaLabel.text = metaParts.joined(separator: " · ")

        configureImages(reply.content.pictures ?? [])
        configureActions(jumpItems: jumpItems)
    }

    // MARK: - 图片

    private func clearImages() {
        for view in imageStackView.arrangedSubviews {
            (view as? UIImageView)?.kf.cancelDownloadTask()
            view.removeFromSuperview()
        }
    }

    private func configureImages(_ pictures: [Replys.Reply.Content.Picture]) {
        clearImages()
        appliedRatios.removeAll()
        pendingImageLoads = 0

        let items = pictures.compactMap { picture -> (String, Replys.Reply.Content.Picture)? in
            guard URL(string: picture.img_src) != nil else { return nil }
            return (picture.img_src, picture)
        }
        imageURLStrings = items.map { $0.0 }
        imageStackView.isHidden = items.isEmpty
        guard !items.isEmpty else { return }

        let generation = configGeneration
        for (index, item) in items.enumerated() {
            let (urlString, picture) = item
            guard let url = URL(string: urlString) else { continue }

            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 16
            imageView.layer.cornerCurve = .continuous
            // 加载完成前保持透明（alpha=0 仍占布局高度、不触发 cell 跳高）：
            // present 转场期间不会露出浅色方框 / 两侧遮盖，也看不到占位比例 → 真实比例的形状变形
            imageView.backgroundColor = .clear
            imageView.alpha = 0
            imageStackView.addArrangedSubview(imageView)

            let initialRatio: CGFloat
            if let w = picture.img_width, let h = picture.img_height, w > 0, h > 0 {
                initialRatio = CGFloat(w) / CGFloat(h)
            } else {
                initialRatio = Self.placeholderRatio
            }
            UIView.performWithoutAnimation {
                applyRatio(initialRatio, to: imageView)
            }
            appliedRatios.append(initialRatio)

            pendingImageLoads += 1
            imageView.kf.setImage(
                with: url,
                options: [.processor(DownsamplingImageProcessor(size: Self.imageProcessorSize))],
                completionHandler: { [weak self, weak imageView] result in
                    guard let self, self.configGeneration == generation, let imageView else { return }
                    self.pendingImageLoads -= 1
                    // 比例校正、强制布局、显形都在无动画上下文里完成：
                    // 图片直接以最终形状出现，不参与 present 转场，也不会从「方形」被拉成「长条」
                    UIView.performWithoutAnimation {
                        if case let .success(value) = result {
                            let size = value.image.size
                            self.updateRatio(size.width / max(size.height, 1), at: index, for: imageView)
                        }
                        self.imageStackView.layoutIfNeeded()
                        imageView.alpha = 1
                    }
                    if self.pendingImageLoads <= 0 {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.configGeneration == generation else { return }
                            self.onImageAspectsResolved?()
                        }
                    }
                }
            )
        }
    }

    /// 宽度铺满 + 高度按宽高比（不超上限）：scaleAspectFit 会把图片等比居中到这个框里，
    /// 竖长图不再被横向等分压成细线；纯约束即可撑开自适应高度，不依赖运行时宽度数值。
    private func applyRatio(_ ratio: CGFloat, to imageView: UIImageView) {
        let safeRatio = max(ratio, 0.05)
        imageView.snp.remakeConstraints { make in
            make.width.equalToSuperview()
            make.height.equalTo(imageView.snp.width).multipliedBy(1.0 / safeRatio).priority(.high)
            make.height.lessThanOrEqualTo(Self.imageMaxHeight)
        }
    }

    private func updateRatio(_ ratio: CGFloat, at index: Int, for imageView: UIImageView) {
        guard index < appliedRatios.count, abs(appliedRatios[index] - ratio) > 0.02 else { return }
        appliedRatios[index] = ratio
        applyRatio(ratio, to: imageView)
    }

    // MARK: - 操作行

    private func configureActions(jumpItems: [JumpItem]) {
        actionStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hasImages = !imageURLStrings.isEmpty
        actionStackView.isHidden = !hasImages && jumpItems.isEmpty
        guard !actionStackView.isHidden else { return }

        if hasImages {
            let button = BLCustomTextButton()
            button.title = imageURLStrings.count > 1 ? "查看大图（\(imageURLStrings.count) 张）" : "查看大图"
            // 卡内按钮只高亮、不放大：基类 1.1 倍放大会探出 containerView 边界被裁
            button.focusScaleFactor = 1.0
            button.onPrimaryAction = { [weak self] _ in
                guard let self else { return }
                self.onOpenImages?(self.imageURLStrings)
            }
            actionStackView.addArrangedSubview(button)
        }
        for item in jumpItems {
            let button = BLCustomTextButton()
            button.title = item.title
            button.focusScaleFactor = 1.0
            button.onPrimaryAction = { [weak self] _ in self?.onJump?(item.bvid) }
            actionStackView.addArrangedSubview(button)
        }
    }
}
