//
//  BLMotionCollectionViewCell.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/10/23.
//

import MarqueeLabel
import TVUIKit
import UIKit

class BLMotionCollectionViewCell: UICollectionViewCell {
    private var motionEffectV: UIInterpolatingMotionEffect!
    private var motionEffectH: UIInterpolatingMotionEffect!
    var scaleFactor: CGFloat = 1.1
    /// 子类需要焦点跑马灯的标题标签: 焦点进入自动续播、离开自动停住; 默认空 = 无跑马灯
    var focusMarqueeLabels: [MarqueeLabel] { [] }
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func setup() {
        motionEffectV = UIInterpolatingMotionEffect(keyPath: "center.y", type: .tiltAlongVerticalAxis)
        motionEffectV.maximumRelativeValue = 8
        motionEffectV.minimumRelativeValue = -8
        motionEffectH = UIInterpolatingMotionEffect(keyPath: "center.x", type: .tiltAlongHorizontalAxis)
        motionEffectH.maximumRelativeValue = 8
        motionEffectH.minimumRelativeValue = -8
    }

    /// 复用/离屏时停住跑马灯 (与失焦同款动作)
    func suspendFocusMarquee() {
        for focusMarqueeLabel in focusMarqueeLabels {
            focusMarqueeLabel.shutdownLabel()
            focusMarqueeLabel.holdScrolling = true
        }
    }

    private func startFocusMarquee() {
        for focusMarqueeLabel in focusMarqueeLabels {
            focusMarqueeLabel.restartLabel()
            focusMarqueeLabel.holdScrolling = false
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if isFocused {
            startFocusMarquee()
            coordinator.addCoordinatedAnimations {
                self.updateTransform()
                self.addMotionEffect(self.motionEffectH)
                self.addMotionEffect(self.motionEffectV)
            }
        } else {
            stopFocusMarquee()
            coordinator.addCoordinatedAnimations {
                self.updateTransform()
                self.removeMotionEffect(self.motionEffectH)
                self.removeMotionEffect(self.motionEffectV)
            }
        }
    }

    private func stopFocusMarquee() {
        for focusMarqueeLabel in focusMarqueeLabels {
            focusMarqueeLabel.shutdownLabel()
            focusMarqueeLabel.holdScrolling = true
        }
    }

    func updateTransform() {
        if isFocused {
            transform = CGAffineTransformMakeScale(scaleFactor, scaleFactor)
            let scaleDiff = (bounds.size.height * scaleFactor - bounds.size.height) / 2
            transform = CGAffineTransformTranslate(transform, 0, -scaleDiff)
            layer.shadowOffset = CGSizeMake(0, 16)
            layer.shadowOpacity = 0.2
            layer.shadowRadius = 18.0
        } else {
            transform = CGAffineTransformIdentity
            layer.shadowOpacity = 0
            layer.shadowOffset = CGSizeMake(0, 0)
        }
    }
}
