//
// Created by Yam on 2024/6/9.
//

import Alamofire
import SnapKit
import UIKit

class ReplyDetailViewController: UIViewController {
    private var contentView: UIView!
    private var titleLabel: UILabel!
    private var collectionView: UICollectionView!

    private let reply: Replys.Reply
    /// jump_url 的 bvid 解析放在 VC 层（cell 不碰异步、不串复用），解析完局部刷新 section 0
    private var jumpItems: [MainReplyCell.JumpItem] = []

    private var hasReplies: Bool { !(reply.replies?.isEmpty ?? true) }

    init(reply: Replys.Reply) {
        self.reply = reply
        super.init(nibName: nil, bundle: nil)
        // 全屏不透明呈现：默认 .automatic 在 tvOS 上会保留底层页面，
        // 展开动画期间新页面透明、与视频详情页重叠，观感很乱
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 视图层级（contentView / collectionView）都是 clear，根视图必须给不透明底色，
        // 否则 present 转场期间会透出底下的视频详情页
        view.backgroundColor = .black
        setUpViews()
        resolveJumpItems()
    }

    // MARK: - Private

    private func jumpLink(bvid: String) {
        let aid = BvidConvertor.bv2av(bvid: bvid)
        let detailVC = VideoDetailViewController.create(aid: Int(aid), cid: nil)
        detailVC.present(from: self)
    }

    private func openImages(_ urlStrings: [String]) {
        guard !urlStrings.isEmpty else { return }
        present(ReplyImageViewerController(imageURLStrings: urlStrings), animated: true)
    }

    private func resolveJumpItems() {
        let entries = reply.content.jump_url ?? [:]
        guard !entries.isEmpty else { return }
        Task { [weak self] in
            var items: [MainReplyCell.JumpItem] = []
            for (url, jump) in entries {
                guard let bvid = await ReplyUrlBVParser.parser(url: url) else { continue }
                items.append(.init(title: jump.title, bvid: bvid))
            }
            guard let self, !items.isEmpty else { return }
            self.jumpItems = items
            // 只重建主评论那一行，让新增的操作行参与自适应高度；关掉动画避免闪一下
            UIView.performWithoutAnimation {
                self.collectionView.reloadItems(at: [IndexPath(item: 0, section: 0)])
            }
        }
    }

    private func setUpViews() {
        contentView = {
            let view = UIView()
            self.view.addSubview(view)
            view.snp.makeConstraints { make in
                make.edges.equalTo(self.view.safeAreaLayoutGuide)
            }
            return view
        }()

        titleLabel = {
            let label = UILabel()
            contentView.addSubview(label)
            label.font = .boldSystemFont(ofSize: 60)
            label.text = "评论"
            label.snp.makeConstraints { make in
                make.centerX.equalToSuperview()
                make.top.equalToSuperview().offset(20)
            }
            return label
        }()

        collectionView = {
            // 整页只有一个滚动容器：主评论作 section 0 首项、子评论 section 1 全宽单列
            let cv = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
            contentView.addSubview(cv)
            cv.dataSource = self
            cv.delegate = self
            cv.backgroundColor = .clear
            cv.register(MainReplyCell.self)
            cv.register(ReplyCell.self)
            cv.snp.makeConstraints { make in
                make.top.equalTo(self.titleLabel.snp.bottom).offset(20)
                make.leading.trailing.bottom.equalToSuperview()
            }
            return cv
        }()
    }

    private func makeLayout() -> UICollectionViewLayout {
        let layout = UICollectionViewCompositionalLayout { sectionIndex, _ in
            let size = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(sectionIndex == 0 ? 300 : 140)
            )
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = .init(top: 0, leading: 60, bottom: 0, trailing: 60)
            section.interGroupSpacing = 10
            return section
        }
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.interSectionSpacing = 20
        layout.configuration = configuration
        return layout
    }
}

extension ReplyDetailViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        hasReplies ? 2 : 1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        section == 0 ? 1 : (reply.replies?.count ?? 0)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if indexPath.section == 0 {
            let cell = collectionView.dequeue(MainReplyCell.self, for: indexPath)
            cell.onJump = { [weak self] bvid in self?.jumpLink(bvid: bvid) }
            cell.onOpenImages = { [weak self] urls in self?.openImages(urls) }
            cell.onImageAspectsResolved = { [weak self] in
                guard let self else { return }
                // 图片真实比例确定后重算一次高度；图片约束已在 cell 内 remake，这里不会重新 config、不会循环
                UIView.performWithoutAnimation {
                    self.collectionView.collectionViewLayout.invalidateLayout()
                    self.collectionView.layoutIfNeeded()
                }
            }
            cell.config(reply: reply, jumpItems: jumpItems)
            return cell
        }

        let cell = collectionView.dequeue(ReplyCell.self, for: indexPath)
        cell.selfSizingContent = true
        if let sub = reply.replies?[indexPath.item] {
            cell.config(replay: sub)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if indexPath.section == 0 {
            // 兜底入口：焦点若落在主评论卡本身（而非内部按钮），按确认键也能打开大图
            let urls = (reply.content.pictures ?? []).compactMap { URL(string: $0.img_src)?.absoluteString }
            if !urls.isEmpty { openImages(urls) }
            return
        }
        guard let sub = reply.replies?[indexPath.item] else { return }
        let detail = ReplyDetailViewController(reply: sub)
        present(detail, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        // 主评论带长图时 cell 远超一屏，焦点从子评论回到它时系统只让局部可见；
        // 显式滚回顶部，保证楼主头像/用户名始终能看到
        guard let next = context.nextFocusedIndexPath, next.section == 0 else { return }
        collectionView.setContentOffset(.zero, animated: true)
    }
}

enum ReplyUrlBVParser {
    static func parser(url: String) async -> String? {
        if url.hasPrefix("BV"), url.count == 12 {
            return url
        }

        if url.hasPrefix("https://www.bilibili.com/video/") {
            guard let urlComponents = URLComponents(string: url)
            else { return nil }
            let path = urlComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let bvid = path.split(separator: "/").filter({ !$0.isEmpty }).last {
                return await parser(url: String(bvid))
            }
            return nil
        }

        // need to get 302 for real url
        if url.hasPrefix("https://b23.tv/") {
            if let realUrl = await AF.request(url, method: .head).serializingData().response.response?.url {
                return await parser(url: realUrl.absoluteString)
            }
        }

        return nil
    }
}
