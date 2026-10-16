//
//  NoteDetailView.swift
//  ATV-Bilibili
//

import SnapKit
import UIKit

class NoteDetailView: UIControl {
    let label = UILabel()
    var onPrimaryAction: ((NoteDetailView) -> Void)?
    private let backgroundView = UIView()
    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func setup() {
        addSubview(backgroundView)
        backgroundView.backgroundColor = UIColor(named: "bgColor")
        backgroundView.layer.shadowOffset = CGSizeMake(0, 10)
        backgroundView.layer.shadowOpacity = 0.15
        backgroundView.layer.shadowRadius = 16.0
        backgroundView.layer.cornerRadius = 20
        backgroundView.layer.cornerCurve = .continuous
        backgroundView.isHidden = !isFocused
        backgroundView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.left.equalToSuperview().offset(-20)
            make.right.equalToSuperview().offset(20)
        }

        addSubview(label)
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 29)
        label.textColor = UIColor(named: "titleColor")
        label.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalToSuperview().offset(14)
            make.bottom.lessThanOrEqualToSuperview().offset(-14)
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        backgroundView.isHidden = !isFocused
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        if presses.first?.type == .select {
            sendActions(for: .primaryActionTriggered)
            onPrimaryAction?(self)
        }
    }
}
