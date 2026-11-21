//
//  NoteDetailView.swift
//  ATV-Bilibili
//

import SnapKit
import UIKit

class NoteDetailView: UIControl {
    let label = UILabel()
    var onPrimaryAction: ((NoteDetailView) -> Void)?
    private let glassView = UIVisualEffectView(effect: BLGlass.effect())
    private let highlightView = UIView()
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let cornerRadius: CGFloat = 20

    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func setup() {
        // 描述卡常态也是玻璃底材：聚焦时只提亮，不再切成一块深色实底
        addSubview(glassView)
        glassView.isUserInteractionEnabled = false
        glassView.clipsToBounds = true
        glassView.layer.cornerRadius = cornerRadius
        glassView.layer.cornerCurve = .continuous
        glassView.alpha = 0.55
        glassView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        highlightView.isUserInteractionEnabled = false
        highlightView.backgroundColor = .clear
        glassView.contentView.addSubview(highlightView)
        highlightView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        chevronView.tintColor = .secondaryLabel
        chevronView.contentMode = .scaleAspectFit
        addSubview(chevronView)
        chevronView.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-22)
            make.centerY.equalToSuperview()
            make.size.equalTo(22)
        }

        addSubview(label)
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 29)
        label.textColor = UIColor.label
        label.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(24)
            make.trailing.equalToSuperview().offset(-56)
            make.top.equalToSuperview().offset(16)
            make.bottom.lessThanOrEqualToSuperview().offset(-16)
        }

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSizeMake(0, 10)
        layer.shadowRadius = 16
        layer.shadowOpacity = 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations {
            self.glassView.alpha = self.isFocused ? 1 : 0.55
            self.highlightView.backgroundColor = UIColor.white.withAlphaComponent(self.isFocused ? 0.10 : 0)
            self.transform = self.isFocused
                ? CGAffineTransform(scaleX: 1.02, y: 1.02)
                : .identity
            self.layer.shadowOpacity = self.isFocused ? 0.18 : 0
            self.chevronView.tintColor = self.isFocused ? .label : .secondaryLabel
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        if presses.first?.type == .select {
            sendActions(for: .primaryActionTriggered)
            onPrimaryAction?(self)
        }
    }
}
