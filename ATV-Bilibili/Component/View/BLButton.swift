//
//  BLButton.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/10/22.
//

import SnapKit
import TVUIKit

@IBDesignable
@MainActor
class BLCustomButton: BLButton {
    @IBInspectable var image: UIImage? {
        didSet { updateButton() }
    }

    @IBInspectable var onImage: UIImage? {
        didSet { updateButton() }
    }

    @IBInspectable var highLightImage: UIImage? {
        didSet { updateButton() }
    }

    @IBInspectable var title: String? {
        didSet {
            updateTitleLabel()
        }
    }

    @IBInspectable var titleColor: UIColor = UIColor.black.withAlphaComponent(0.9) {
        didSet { titleLabel.textColor = titleColor }
    }

    @IBInspectable var titleFont: UIFont = .systemFont(ofSize: 24) {
        didSet { titleLabel.font = titleFont }
    }

    var isOn: Bool = false {
        didSet {
            updateButton()
        }
    }

    private let titleLabel = UILabel()
    private let imageView = UIImageView()

    override func setup() {
        super.setup()
        titleLabel.isUserInteractionEnabled = false
        effectView.contentView.addSubview(imageView)
        imageView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.height.equalToSuperview().multipliedBy(0.5)
            make.height.equalTo(imageView.snp.width)
        }
        imageView.image = image
        addSubview(titleLabel)
        titleLabel.textAlignment = .center
        titleLabel.font = titleFont
        titleLabel.textColor = titleColor
        updateTitleLabel(force: true)
    }

    private func updateTitleLabel(force: Bool = false) {
        let shouldHide = title == nil || title?.count == 0
        titleLabel.text = title
        accessibilityLabel = title
        if force || titleLabel.isHidden != shouldHide {
            titleLabel.isHidden = shouldHide
            if shouldHide {
                titleLabel.snp.removeConstraints()
            } else {
                titleLabel.snp.makeConstraints { make in
                    make.leading.trailing.bottom.equalToSuperview()
                    make.top.equalTo(effectView.snp.bottom).offset(10)
                }
            }
        }
    }

    private func getImage() -> UIImage? {
        isOn ? onImage : image
    }

    private func updateButton() {
        if isFocused {
            imageView.image = highLightImage ?? getImage()
            imageView.tintColor = .black
        } else {
            imageView.image = getImage()
            imageView.tintColor = .white
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        updateButton()
    }
}

@IBDesignable
@MainActor
class BLCustomTextButton: BLButton {
    private let titleLabel = UILabel()
    var object: Any?

    @IBInspectable var title: String? {
        didSet {
            titleLabel.text = title
            accessibilityLabel = title
        }
    }

    @IBInspectable var titleColor: UIColor = .white {
        didSet { titleLabel.textColor = titleColor }
    }

    /// 聚焦态标题色；生效点在 setup()/didUpdateFocus() 的 isFocused 三元，无需 didSet
    @IBInspectable var titleSelectedColor: UIColor = .black

    @IBInspectable var titleFont: UIFont = .systemFont(ofSize: 28) {
        didSet { titleLabel.font = titleFont }
    }

    override func setup() {
        super.setup()
        effectView.contentView.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview().inset(10)
            make.left.right.equalToSuperview().inset(24)
        }
        titleLabel.text = title
        titleLabel.font = titleFont
        titleLabel.textColor = isFocused ? titleSelectedColor : titleColor
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        titleLabel.textColor = isFocused ? titleSelectedColor : titleColor
    }
}

class BLButton: UIControl {
    private var motionEffect: UIInterpolatingMotionEffect!
    fileprivate let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let selectedWhiteView = UIView()
    /// 玻璃边缘高光：与 `BLCapsuleEffectView` 同一套（系统玻璃在薄胶囊上高光不够明显）
    private let glassRim = BLGlassRimView()

    /// 默认 nil = 保持 .dark 模糊（既有用点零变化）；需要玻璃观感的调用方传入 BLGlass.effect()
    var backgroundEffect: UIVisualEffect? {
        didSet { effectView.effect = backgroundEffect ?? UIBlurEffect(style: .dark) }
    }

    var onPrimaryAction: ((BLButton) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var canBecomeFocused: Bool { return true }

    func setup() {
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        motionEffect = UIInterpolatingMotionEffect(keyPath: "center.x", type: .tiltAlongHorizontalAxis)
        motionEffect.maximumRelativeValue = 8
        motionEffect.minimumRelativeValue = -8
        selectedWhiteView.isHidden = !isFocused
        addSubview(effectView)
        effectView.isUserInteractionEnabled = false
        effectView.layer.cornerRadius = 16
        effectView.clipsToBounds = true
        effectView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.equalToSuperview().priority(.high)
        }
        glassRim.frame = effectView.contentView.bounds
        glassRim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        effectView.contentView.addSubview(glassRim)
        effectView.contentView.addSubview(selectedWhiteView)
        selectedWhiteView.backgroundColor = UIColor.white
        selectedWhiteView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    // 胶囊形圆角: 圆角=高度一半, 宽扁按钮呈胶囊、近方形图标按钮呈圆形 (对齐 tvOS 系统按钮与 B 站客户端风格)
    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = effectView.bounds.height / 2
        effectView.layer.cornerRadius = radius.isFinite ? radius : 16
        glassRim.frame = effectView.contentView.bounds
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        if presses.first?.type == .select {
            sendActions(for: .primaryActionTriggered)
            onPrimaryAction?(self)
        }
    }

    /// 聚焦态切换回调（例如焦点白底上需要换深色文字）
    var onFocusChanged: ((Bool) -> Void)?

    /// 聚焦放大倍数；卡内按钮设 1.0 可只保留高亮、不放大（放大后容易超出卡片边界）
    var focusScaleFactor: CGFloat = 1.1

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        onFocusChanged?(isFocused)
        if isFocused {
            selectedWhiteView.isHidden = false
            coordinator.addCoordinatedAnimations {
                let scale = self.focusScaleFactor
                self.transform = CGAffineTransformMakeScale(scale, scale)
                let scaleDiff = (self.bounds.size.height * scale - self.bounds.size.height) / 2
                self.transform = CGAffineTransformTranslate(self.transform, 0, -scaleDiff)
                self.layer.shadowOffset = CGSizeMake(0, 10)
                self.layer.shadowOpacity = 0.15
                self.layer.shadowRadius = 16.0
                self.addMotionEffect(self.motionEffect)
            }
        } else {
            selectedWhiteView.isHidden = true
            coordinator.addCoordinatedAnimations {
                self.transform = CGAffineTransformIdentity
                self.layer.shadowOpacity = 0
                self.layer.shadowOffset = CGSizeMake(0, 0)
                self.removeMotionEffect(self.motionEffect)
            }
        }
    }
}
