//
//  SettingsViewController.swift
//  ATV-Bilibili
//
//  Created by whw on 2022/10/19.
//

import UIKit

class SettingsViewController: UIViewController {
    static let headerKind = "header"

    class SectionModel: Hashable, Equatable {
        let title: String
        let items: [CellModel]

        init(title: String, @ArrayBuilder<CellModel> items: () -> [CellModel]) {
            self.title = title
            self.items = items()
        }

        static func == (lhs: SectionModel, rhs: SectionModel) -> Bool {
            lhs.title == rhs.title && lhs.items == rhs.items
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(title)
            hasher.combine(items)
        }
    }

    class CellModel: Hashable, Equatable {
        let title: String
        let desp: () -> String
        let action: ((@escaping () -> Void) -> Void)?

        var updateAction: (() -> Void)?

        func hash(into hasher: inout Hasher) {
            hasher.combine(title)
        }

        static func == (lhs: CellModel, rhs: CellModel) -> Bool {
            lhs.title == rhs.title
        }

        init(title: String, desp: @autoclosure @escaping () -> String, action: ((@escaping () -> Void) -> Void)?) {
            self.title = title
            self.desp = desp
            self.action = action
        }
    }

    let collectionView: UICollectionView = {
        let layout = UICollectionViewCompositionalLayout { sectionIndex, environment -> NSCollectionLayoutSection? in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(68))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)

            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(68))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
            group.interItemSpacing = .fixed(10)

            let section = NSCollectionLayoutSection(group: group)
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(44)
            )

            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: SettingsViewController.headerKind,
                alignment: .top
            )
            header.pinToVisibleBounds = false
            section.boundarySupplementaryItems = [header]
            section.interGroupSpacing = 10
            return section
        }
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()

    var dataSource: UICollectionViewDiffableDataSource<SectionModel, CellModel>!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(collectionView)
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.snp.makeConstraints { make in
            make.top.right.bottom.equalToSuperview()
            make.left.equalToSuperview().offset(20)
        }

        collectionView.delegate = self
        collectionView.register(SettingsSwitchCell.self)
        collectionView.register(SettingsHeaderView.self, forSupplementaryViewOfKind: SettingsViewController.headerKind)

        configureDataSource()
        setupData()
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<SectionModel, CellModel>(collectionView: collectionView) { collectionView, indexPath, cellModel -> UICollectionViewCell? in
            let cell = collectionView.dequeue(SettingsSwitchCell.self, for: indexPath)
            cell.set(with: cellModel)
            return cell
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let header = collectionView.dequeue(SettingsHeaderView.self, ofKind: kind, for: indexPath)
            let title = self?.dataSource.snapshot().sectionIdentifiers[indexPath.section].title ?? UUID().uuidString

            header.label.text = title
            return header
        }
    }

    private func setupData() {
        createSnapshot {
            SectionModel(title: "通用") {
                Toggle(title: "启用投屏", setting: Settings.enableDLNA, onChange: Settings.enableDLNA.toggle()) {
                    _ in
                    BiliBiliUpnpDMR.shared.start()
                }

                Toggle(title: "热门个性化推荐", setting: Settings.requestHotWithoutCookie, onChange: Settings.requestHotWithoutCookie.toggle())

                Actions(title: "Top Shelf 内容来源", message: "Apple TV 主屏顶部展示的内容, 修改后需回到主屏等待刷新",
                        current: Settings.topShelfSource.title,
                        options: TopShelfSource.allCases,
                        optionString: TopShelfSource.allCases.map({ $0.title }))
                {
                    Settings.topShelfSource = $0
                    TopShelfSyncManager.shared.refresh(force: true)
                }

                // Top Shelf 排障用入口: 平时不显示状态, 点按才刷新并弹窗展示
                CellModel(title: "Top Shelf 数据诊断", desp: "") { [weak self] update in
                    Task { @MainActor in
                        let message = await TopShelfSyncManager.shared.refreshAndReport(force: true)
                        self?.presentAlert(title: "Top Shelf 状态", message: message)
                        update()
                    }
                }

                CellModel(title: "关于", desp: "\(BuildInfo.marketingVersion) (\(BuildInfo.commitHash))") { [weak self] update in
                    let message = """
                    版本: \(BuildInfo.marketingVersion)
                    构建: \(BuildInfo.buildNumber)
                    提交: \(BuildInfo.commitHash)
                    """
                    self?.presentAlert(title: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "哔哩哔哩", message: message)
                    update()
                }
            }

            SectionModel(title: "界面") {
                Navigation(title: "自定义Tab栏", desp: "") { [weak self] in
                    let controller = TabBarCustomizationViewController()
                    self?.present(controller, animated: true)
                }

                Actions(title: "视频每行显示个数", message: "重启app生效",
                        current: Settings.displayStyle.desp,
                        options: FeedDisplayStyle.allCases.filter({ !$0.hideInSetting }),
                        optionString: FeedDisplayStyle.allCases.filter({ !$0.hideInSetting }).map({ $0.desp }))
                {
                    Settings.displayStyle = $0
                }
                Toggle(title: "侧边栏菜单自动切换", setting: Settings.sideMenuAutoSelectChange, onChange: Settings.sideMenuAutoSelectChange.toggle())

                Toggle(title: "不显示详情页直接进入视频",
                       setting: Settings.directlyEnterVideo,
                       onChange: Settings.directlyEnterVideo.toggle())

                Actions(title: "视频详情相关推荐加载模式", message: "4k以上需要大会员",
                        current: Settings.showRelatedVideoInCurrentVC ? "页面刷新" : "新页面中打开",
                        options: [true, false],
                        optionString: ["页面刷新", "新页面中打开"])
                {
                    Settings.showRelatedVideoInCurrentVC = $0
                }
            }

            SectionModel(title: "推荐") {
                Toggle(title: "使用沉浸式浏览模式",
                       setting: Settings.recommendFeedFlowEnabled,
                       onChange: Settings.recommendFeedFlowEnabled.toggle())
                Actions(title: "沉浸式视频时长上限", message: "用于筛选沉浸式推荐中的短视频",
                        current: Settings.featuredDurationLimit.title,
                        options: FeaturedDurationLimit.allCases,
                        optionString: FeaturedDurationLimit.allCases.map { $0.title })
                {
                    Settings.featuredDurationLimit = $0
                }
                Toggle(title: "沉浸式推荐内容安全过滤",
                       setting: Settings.featuredContentSafetyFilterEnabled,
                       onChange: Settings.featuredContentSafetyFilterEnabled.toggle())
            }

            SectionModel(title: "关注页面") {
                Toggle(title: "关注刷视频模式",
                       setting: Settings.followsFeedFlowEnabled,
                       onChange: Settings.followsFeedFlowEnabled.toggle())
                { _ in
                    NotificationCenter.default.post(name: .followsLayoutModeDidChange, object: nil)
                }
            }

            SectionModel(title: "音视频") {
                Actions(title: "最高画质", message: "4k以上需要大会员",
                        current: Settings.mediaQuality.desp,
                        options: MediaQualityEnum.allCases,
                        optionString: MediaQualityEnum.allCases.map({ $0.desp }))
                {
                    Settings.mediaQuality = $0
                }
                Actions(title: "默认播放速度", message: "新视频默认沿用上次选择的倍速",
                        current: Settings.mediaPlayerSpeed.name,
                        options: PlaySpeed.blDefaults,
                        optionString: PlaySpeed.blDefaults.map({ $0.name }))
                {
                    Settings.mediaPlayerSpeed = $0
                }
                Toggle(title: "Avc优先(卡顿尝试开启)", setting: Settings.preferAvc, onChange: Settings.preferAvc.toggle())
                Toggle(title: "无损音频和杜比全景声", setting: Settings.losslessAudio, onChange: Settings.losslessAudio.toggle())
                Toggle(title: "匹配视频内容", setting: Settings.contentMatch, onChange: Settings.contentMatch.toggle())
                Toggle(title: "仅在HDR视频匹配视频内容", setting: Settings.contentMatchOnlyInHDR, onChange: Settings.contentMatchOnlyInHDR.toggle())
            }

            SectionModel(title: "进度控制") {
                Toggle(title: "从上次退出的位置继续播放", setting: Settings.continuePlay, onChange: Settings.continuePlay.toggle())
                Toggle(title: "自动跳过片头片尾", setting: Settings.autoSkip, onChange: Settings.autoSkip.toggle())
                Toggle(title: "连续播放", setting: Settings.continuouslyPlay, onChange: Settings.continuouslyPlay.toggle())
                Actions(title: "空降助手广告屏蔽", message: "",
                        current: Settings.enableSponsorBlock.title,
                        options: SponsorBlockType.allCases,
                        optionString: SponsorBlockType.allCases.map({ $0.title }))
                {
                    Settings.enableSponsorBlock = $0
                }
            }

            SectionModel(title: "弹幕") {
                Toggle(title: "用户自定义弹幕屏蔽", setting: Settings.enableDanmakuFilter, onChange: Settings.enableDanmakuFilter.toggle()) {
                    enable in
                    if enable {
                        Task {
                            let toast = await VideoDanmakuFilter.shared.update()
                            self.presentDanmakuSyncResult(toast)
                        }
                    }
                }
                CellModel(title: "同步云端弹幕屏蔽词", desp: VideoDanmakuFilter.shared.syncStatusDescription) { [weak self] update in
                    Task { @MainActor in
                        let toast = await VideoDanmakuFilter.shared.update()
                        self?.presentDanmakuSyncResult(toast)
                        update()
                    }
                }
                TextField(title: "添加本地屏蔽词", message: "新增关键字屏蔽(大小写不敏感)，随「用户自定义弹幕屏蔽」开关一起生效",
                          current: "", placeholder: "输入要屏蔽的关键字")
                { word in
                    guard let word else { return }
                    VideoDanmakuFilter.shared.addLocalFilter(word)
                }
                CellModel(title: "管理本地屏蔽词", desp: "\(VideoDanmakuFilter.shared.localFilterCount) 条") { [weak self] update in
                    self?.presentLocalFilterManageAlert(onChange: update)
                }
                Toggle(title: "移除重复弹幕", setting: Settings.enableDanmakuRemoveDup, onChange: Settings.enableDanmakuRemoveDup.toggle())
                Actions(title: "弹幕大小", message: "默认为36", current: Settings.danmakuSize.title, options: DanmakuSize.allCases, optionString: DanmakuSize.allCases.map({ $0.title })) {
                    Settings.danmakuSize = $0
                }
                Actions(title: "弹幕显示区域", message: "设置弹幕显示区域",
                        current: Settings.danmakuArea.title,
                        options: DanmakuArea.allCases,
                        optionString: DanmakuArea.allCases.map({ $0.title }))
                {
                    Settings.danmakuArea = $0
                }
                Toggle(title: "智能防档弹幕", setting: Settings.danmakuMask, onChange: Settings.danmakuMask.toggle())
                Toggle(title: "按需本地运算智能防档弹幕(Exp)", setting: Settings.vnMask, onChange: Settings.vnMask.toggle())

                // 添加弹幕透明度设置
                Actions(title: "弹幕透明度", message: "调整弹幕的透明度",
                        current: Settings.danmakuAlpha.title,
                        options: DanmakuAlpha.allCases,
                        optionString: DanmakuAlpha.allCases.map({ $0.title }))
                { value in
                    Settings.danmakuAlpha = value
                }

                // 添加弹幕描边宽度设置
                Actions(title: "弹幕描边宽度", message: "调整弹幕描边的粗细",
                        current: Settings.danmakuStrokeWidth.title,
                        options: DanmakuStrokeWidth.allCases,
                        optionString: DanmakuStrokeWidth.allCases.map({ $0.title }))
                { value in
                    Settings.danmakuStrokeWidth = value
                }

                // 添加弹幕描边透明度设置
                Actions(title: "弹幕描边透明度", message: "调整弹幕描边的透明度",
                        current: Settings.danmakuStrokeAlpha.title,
                        options: DanmakuStrokeAlpha.allCases,
                        optionString: DanmakuStrokeAlpha.allCases.map({ $0.title }))
                { value in
                    Settings.danmakuStrokeAlpha = value
                }
            }

            SectionModel(title: "港澳台解锁") {
                Toggle(title: "解锁港澳台番剧限制", setting: Settings.areaLimitUnlock, onChange: Settings.areaLimitUnlock.toggle())
                TextField(title: "设置港澳台解析服务器", message: "为了安全考虑建议自建服务器，公共服务器可用性难保证，请多尝试几个。\n公共服务器请参考：http://985.so/mjq9u", current: Settings.areaLimitCustomServer, placeholder: "api.example.com") {
                    Settings.areaLimitCustomServer = $0 ?? ""
                }
            }
        }
    }
}

extension SettingsViewController {
    /// 弹幕屏蔽词同步完成后展示结果弹窗（开关开启与手动同步两个入口共用）
    private func presentDanmakuSyncResult(_ toast: String) {
        presentAlert(title: "同步结果", message: toast, buttonTitle: "Ok")
    }

    /// 本地弹幕屏蔽词管理：逐词删除。词表一般很短，actionSheet 逐词按钮足够；
    /// tvOS 没有现成的多行列表编辑控件
    private func presentLocalFilterManageAlert(onChange: @escaping () -> Void) {
        let words = Settings.localDanmakuFilters
        guard !words.isEmpty else {
            presentAlert(title: "管理本地屏蔽词", message: "还没有本地屏蔽词，先用「添加本地屏蔽词」加一条吧")
            return
        }
        let alert = UIAlertController(title: "管理本地屏蔽词", message: "选择要删除的词", preferredStyle: .actionSheet)
        for word in words {
            alert.addAction(UIAlertAction(title: word, style: .destructive) { _ in
                VideoDanmakuFilter.shared.removeLocalFilter(word)
                onChange()
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    func Toggle(title: String, setting: @autoclosure @escaping () -> Bool,
                onChange: @autoclosure @escaping () -> Void,
                extraAction: ((Bool) -> Void)? = nil) -> CellModel
    {
        return CellModel(title: title, desp: setting() ? "开" : "关") {
            update in
            onChange()
            extraAction?(setting())
            update()
        }
    }

    func Actions<T>(title: String,
                    message: String?,
                    current: @autoclosure @escaping () -> String,
                    options: [T],
                    optionString: [String],
                    onSelect: ((T) -> Void)? = nil) -> CellModel
    {
        return CellModel(title: title, desp: current()) { [weak self] update in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)

            for (idx, string) in optionString.enumerated() {
                let action = UIAlertAction(title: string, style: .default) { _ in
                    onSelect?(options[idx])
                    update()
                }
                alert.addAction(action)
            }
            let cancelAction = UIAlertAction(title: nil, style: .cancel)
            alert.addAction(cancelAction)
            self?.present(alert, animated: true)
        }
    }

    func TextField(title: String,
                   message: String?,
                   current: String,
                   placeholder: String?,
                   isSecureTextEntry: Bool = false,
                   onSubmit: ((String?) -> Void)? = nil) -> CellModel
    {
        return CellModel(title: title, desp: current) { [weak self] update in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addTextField { textField in
                textField.text = current
                textField.keyboardType = .URL
                textField.placeholder = placeholder
                textField.isSecureTextEntry = isSecureTextEntry
            }

            let action = UIAlertAction(title: "确定", style: .default) { _ in
                onSubmit?(alert.textFields![0].text)
                update()
            }
            alert.addAction(action)

            let cancelAction = UIAlertAction(title: nil, style: .cancel)
            alert.addAction(cancelAction)
            self?.present(alert, animated: true)
        }
    }

    func Navigation(title: String,
                    desp: @autoclosure @escaping () -> String,
                    onSelect: (() -> Void)? = nil) -> CellModel
    {
        return CellModel(title: title, desp: desp()) { update in
            onSelect?()
            update()
        }
    }
}

extension SettingsViewController: UICollectionViewDelegate {
    private func createSnapshot(@ArrayBuilder<SectionModel> builder: () -> [SectionModel]) {
        var snapshot = NSDiffableDataSourceSnapshot<SectionModel, CellModel>()
        for section in builder() {
            snapshot.appendSections([section])
            snapshot.appendItems(section.items, toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let cellModel = dataSource.itemIdentifier(for: indexPath)!
        cellModel.action?() { [weak cellModel] in
            cellModel?.updateAction?()
        }
    }
}

extension FeedDisplayStyle {
    var desp: String {
        switch self {
        case .large:
            return "3个"
        case .normal:
            return "4个"
        case .sideBar:
            return "-"
        }
    }
}
