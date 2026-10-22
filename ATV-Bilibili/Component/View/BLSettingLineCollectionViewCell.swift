//
//  BLSettingLineCollectionViewCell.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/10/29.
//

import UIKit

class BLSettingLineCollectionViewCell: BLMotionCollectionViewCell {
    /// tvOS 26+: 选中/聚焦时才浮现的 Liquid Glass 胶囊(懒加载, 对齐系统 Tab 栏的处理: 默认隐身)
    private var glassView: UIVisualEffectView?
    /// tvOS 18 回退: 浅色模糊胶囊容器
    private let effectView = BLCapsuleEffectView(effect: UIBlurEffect(style: .light))
    /// tvOS 18 回退: 白色选中高亮
    private let selectedWhiteView = UIView()
    let titleLabel = UILabel()

    private var usesGlassStyle: Bool {
        if #available(tvOS 26.0, *) { return true }
        return false
    }

    /// 选中态对比增强（「我的」侧边栏用）：未选中文字降为半透明，选中/聚焦全亮加粗；
    /// 默认关闭，排行榜分类等普通列表不受影响
    var enhancesSelectionContrast = false

    /// 「我的」页面这类可进入的列表项：右侧显示一个箭头（排行榜分类等纯选择项不显示）
    var showsDisclosureIndicator = false {
        didSet { chevronView.isHidden = !showsDisclosureIndicator }
    }

    private let chevronView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "chevron.right"))
        imageView.tintColor = UIColor.black.withAlphaComponent(0.35)
        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = true
        return imageView
    }()

    override var isSelected: Bool {
        didSet {
            updateView()
        }
    }

    override var accessibilityLabel: String? {
        get { titleLabel.text }
        set {}
    }

    override func setup() {
        super.setup()
        scaleFactor = 1.05
        isAccessibilityElement = true
        accessibilityTraits = .button
        if usesGlassStyle {
            // Liquid Glass 风格: 胶囊默认隐身, 选中/聚焦才浮现; 侧栏铺在系统底色上随明暗模式,
            // 文字用语义色自适应(浅底深字/深底白字), 浮现的玻璃胶囊吸取背后明度, 两种模式均可读
            installContent(in: contentView)
            titleLabel.textColor = .label
            chevronView.tintColor = .secondaryLabel
        } else {
            // tvOS 18 回退: 保持原浅色模糊胶囊 + 白色高亮
            effectView.clipsToBounds = true
            contentView.addSubview(effectView)
            effectView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            selectedWhiteView.backgroundColor = UIColor.white
            selectedWhiteView.isHidden = !isFocused
            effectView.contentView.addSubview(selectedWhiteView)
            selectedWhiteView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            installContent(in: effectView.contentView)
            titleLabel.textColor = .black
        }
    }

    /// 文字与箭头装进指定容器(玻璃样式装 contentView, 回退样式装模糊层 contentView), 两个分支约束保持一致
    private func installContent(in container: UIView) {
        container.addSubview(chevronView)
        chevronView.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-34)
            make.centerY.equalToSuperview()
            make.width.equalTo(16)
        }

        container.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(30)
            make.trailing.equalToSuperview().offset(-74)
            make.top.bottom.equalToSuperview().inset(8)
        }
        titleLabel.textAlignment = .left
        titleLabel.font = UIFont.systemFont(ofSize: 40, weight: .regular)
    }

    /// 玻璃胶囊懒加载: 复用 BLCapsuleEffectView(圆角在自身 layoutSubviews 按高度自适应), 放到文字下层
    @available(tvOS 26.0, *)
    private func ensureGlassView() -> UIVisualEffectView {
        if let glassView = glassView { return glassView }
        let view = BLCapsuleEffectView(effect: UIGlassEffect(style: .regular))
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        contentView.addSubview(view)
        view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        contentView.sendSubviewToBack(view)
        glassView = view
        return view
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        updateView()
    }

    func updateView() {
        let highlighted = isFocused || isSelected
        if usesGlassStyle {
            if #available(tvOS 26.0, *) {
                ensureGlassView().isHidden = !highlighted
            }
            if enhancesSelectionContrast {
                titleLabel.textColor = highlighted ? .label : .secondaryLabel
                titleLabel.font = .systemFont(ofSize: 40, weight: highlighted ? .medium : .regular)
            }
        } else {
            selectedWhiteView.isHidden = !highlighted
        }
    }

    static func makeLayout() -> UICollectionViewLayout {
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(0.9),
                                              heightDimension: .fractionalHeight(1.0))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                               heightDimension: .absolute(70))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize,
                                                       subitems: [item])
        group.edgeSpacing = .init(leading: nil, top: .fixed(10), trailing: nil, bottom: nil)
        let section = NSCollectionLayoutSection(group: group)
        let layout = UICollectionViewCompositionalLayout(section: section)
        return layout
    }
}
