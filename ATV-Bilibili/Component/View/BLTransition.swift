//
//  BLTransition.swift
//  ATV-Bilibili
//
//  页面切换过渡: 居中浮现 (淡入 + 0.96→1.0 弹簧缩放), 展示/关闭双向对称。
//  用法: 目标 VC 设置 modalPresentationStyle = .custom, transitioningDelegate = BLTransition.shared
//

import UIKit

class BLTransition: NSObject, UIViewControllerTransitioningDelegate {
    static let shared = BLTransition()

    func animationController(forPresented _: UIViewController,
                             presenting _: UIViewController,
                             source _: UIViewController) -> UIViewControllerAnimatedTransitioning?
    {
        BLTransitionAnimator(presenting: true)
    }

    func animationController(forDismissed _: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        BLTransitionAnimator(presenting: false)
    }

    func presentationController(forPresented presented: UIViewController,
                                presenting: UIViewController?,
                                source _: UIViewController) -> UIPresentationController?
    {
        BLPresentationController(presentedViewController: presented, presenting: presenting)
    }
}

/// 全屏呈现容器 (与系统 fullScreen 一致: 转场后移除下层视图, 释放其资源)
class BLPresentationController: UIPresentationController {
    override var shouldRemovePresentersView: Bool { true }
}

class BLTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool

    init(presenting: Bool) {
        self.presenting = presenting
        super.init()
    }

    func transitionDuration(using _: UIViewControllerContextTransitioning?) -> TimeInterval {
        presenting ? 0.38 : 0.32
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView

        guard let toView = transitionContext.view(forKey: .to),
              let fromView = transitionContext.view(forKey: .from)
        else {
            transitionContext.completeTransition(true)
            return
        }

        if presenting {
            container.addSubview(toView)
            toView.alpha = 0
            toView.transform = CGAffineTransformScale(CGAffineTransformIdentity, 0.96, 0.96)
            UIView.animate(
                withDuration: transitionDuration(using: transitionContext),
                delay: 0,
                usingSpringWithDamping: 0.85,
                initialSpringVelocity: 0.4,
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                toView.alpha = 1
                toView.transform = CGAffineTransformIdentity
                fromView.alpha = 0.35
            } completion: { _ in
                fromView.alpha = 1
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            }
        } else {
            container.insertSubview(toView, at: 0)
            toView.alpha = 0.35
            UIView.animate(
                withDuration: transitionDuration(using: transitionContext),
                delay: 0,
                options: [.curveEaseIn, .allowUserInteraction]
            ) {
                fromView.alpha = 0
                fromView.transform = CGAffineTransformScale(CGAffineTransformIdentity, 0.96, 0.96)
                toView.alpha = 1
            } completion: { _ in
                fromView.transform = CGAffineTransformIdentity
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            }
        }
    }
}
