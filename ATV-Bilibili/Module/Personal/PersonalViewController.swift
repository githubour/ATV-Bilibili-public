//
//  PersonalViewController.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2022/8/20.
//

import Alamofire
import Kingfisher
import SnapKit
import UIKit

class PersonalViewController: UIViewController, BLTabBarContentVCProtocol, ChildContentContainer {
    struct CellModel {
        let title: String
        /// 对应的导航栏页面, 仅内容页有值（用于决定默认落地页）
        var page: TabBarPage? = nil
        var autoSelect: Bool? = true
        var contentVC: UIViewController? = nil
        var action: (() -> Void)? = nil
    }

    static func create() -> PersonalViewController {
        return PersonalViewController()
    }

    private let leftContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let profileContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    let contentView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let avatarImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private let usernameLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let leftCollectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 16
        layout.minimumInteritemSpacing = 4
        layout.itemSize = CGSize(width: 340, height: 60)
        layout.sectionInset = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        return collectionView
    }()

    weak var currentViewController: UIViewController?

    var cellModels = [CellModel]()
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupData()
        leftCollectionView.reloadData()
        avatarImageView.layer.cornerRadius = 50
        leftCollectionView.register(BLSettingLineCollectionViewCell.self)
        selectDefaultItem()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAccountUpdate),
                                               name: AccountManager.didUpdateNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleTabBarPagesDidChange),
                                               name: .tabBarPagesDidChange,
                                               object: nil)
        updateAccountInfo()
        Task { await AccountManager.shared.refreshActiveAccountProfile() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setupData() {
        cellModels.removeAll()

        // 内容页排在最前：点进「我的」看到的是内容，而不是一屏设置项
        for page in Settings.personalPages {
            if let model = makeCellModel(for: page) {
                cellModels.append(model)
            }
        }

        // 账号与设置类条目收在列表末尾
        cellModels.append(CellModel(title: "账号切换", autoSelect: false, action: { [weak self] in
            let controller = AccountSwitcherViewController()
            controller.modalPresentationStyle = .overFullScreen
            self?.present(controller, animated: true)
        }))
        cellModels.append(CellModel(title: "设置", contentVC: SettingsViewController()))
        cellModels.append(CellModel(title: "登出", autoSelect: false) {
            [weak self] in
            self?.actionLogout()
        })
    }

    /// 「我的」默认落地页：优先历史记录（对齐官方 TV 版），否则退回第一个内容页
    private var defaultSelectionIndex: Int {
        if let history = cellModels.firstIndex(where: { $0.page == .history && $0.contentVC != nil }) {
            return history
        }
        return cellModels.firstIndex { $0.contentVC != nil } ?? 0
    }

    private func makeCellModel(for page: TabBarPage) -> CellModel? {
        let vc = TabBarPageVCFactory.createVC(for: page)
        if page.requirePresentInPersonalPage {
            // 需要整屏展示的页面（收藏/搜索等）只在按下确认键时打开，
            // 否则光标扫过就弹出整屏页面很突兀
            return CellModel(title: page.title, page: page, autoSelect: false) { [weak self] in
                self?.present(vc, animated: true)
            }
        }

        // 可直接嵌入的内容页：光标移到哪一项，右侧就预览哪一项
        return CellModel(title: page.title, page: page, contentVC: vc)
    }

    func reloadData() {
        forwardReloadToContentViewController()
    }

    func actionLogout() {
        presentConfirm(title: "确定登出？", confirmTitle: "确定") { [weak self] in
            Task { [weak self] in
                await WebRequest.logout()
                let hasRemainingAccount = ApiRequest.logout()
                // 登录态落定后立刻刷新 Top Shelf: 登出清掉个人数据, 换号拉新数据
                TopShelfSyncManager.shared.refresh(force: true)
                if hasRemainingAccount {
                    await AccountManager.shared.refreshActiveAccountProfile()
                } else {
                    await MainActor.run {
                        self?.presentedViewController?.dismiss(animated: false)
                        AppDelegate.shared.showLogin()
                    }
                }
            }
        }
    }

    @objc private func handleAccountUpdate() {
        updateAccountInfo()
    }

    @objc private func handleTabBarPagesDidChange() {
        setupData()
        leftCollectionView.reloadData()
        selectDefaultItem()
    }

    /// 选中默认落地页并把右侧内容切换过去（不触发弹窗类条目的 action）
    private func selectDefaultItem() {
        let indexPath = IndexPath(item: defaultSelectionIndex, section: 0)
        leftCollectionView.selectItem(at: indexPath, animated: false, scrollPosition: .top)
        let model = cellModels[indexPath.item]
        if let vc = model.contentVC {
            setViewController(vc: vc)
        }
    }

    private func updateAccountInfo() {
        guard let account = AccountManager.shared.activeAccount else {
            usernameLabel.text = "未登录"
            avatarImageView.image = nil
            return
        }
        usernameLabel.text = account.profile.username
        avatarImageView.setAccountAvatar(with: account.profile.avatar)
    }

    private func setupUI() {
        view.addSubview(leftContainerView)
        view.addSubview(contentView)

        leftContainerView.addSubview(profileContainerView)
        leftContainerView.addSubview(leftCollectionView)

        profileContainerView.addSubview(avatarImageView)
        profileContainerView.addSubview(usernameLabel)

        leftCollectionView.delegate = self
        leftCollectionView.dataSource = self

        leftContainerView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.bottom.equalToSuperview()
            make.width.equalTo(380)
        }

        contentView.snp.makeConstraints { make in
            make.leading.equalTo(leftContainerView.snp.trailing).offset(8)
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.trailing.bottom.equalToSuperview()
        }

        profileContainerView.snp.makeConstraints { make in
            make.leading.top.trailing.equalToSuperview()
            make.height.equalTo(100)
        }

        avatarImageView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(20)
            make.top.bottom.equalToSuperview()
            make.width.equalTo(avatarImageView.snp.height)
        }

        usernameLabel.snp.makeConstraints { make in
            make.leading.equalTo(avatarImageView.snp.trailing).offset(20)
            make.trailing.equalToSuperview().offset(-20)
            make.centerY.equalTo(avatarImageView.snp.centerY)
        }

        leftCollectionView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.top.equalTo(profileContainerView.snp.bottom).offset(40)
        }
    }
}

extension PersonalViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeue(BLSettingLineCollectionViewCell.self, for: indexPath)
        cell.titleLabel.text = cellModels[indexPath.item].title
        cell.showsDisclosureIndicator = true
        cell.enhancesSelectionContrast = true
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return cellModels.count
    }
}

extension PersonalViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let model = cellModels[indexPath.item]
        if let vc = model.contentVC {
            setViewController(vc: vc)
        }
        model.action?()
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        if Settings.sideMenuAutoSelectChange == false {
            return
        }
        // 检查新的焦点是否是UICollectionViewCell
        guard let nextFocusedIndexPath = context.nextFocusedIndexPath else {
            return
        }
        let model = cellModels[nextFocusedIndexPath.item]
        if model.autoSelect == false {
            // 不自动选中
            return
        }
        collectionView.selectItem(at: nextFocusedIndexPath, animated: true, scrollPosition: .centeredHorizontally)
        if let vc = model.contentVC {
            setViewController(vc: vc)
        }
        model.action?()
    }
}
