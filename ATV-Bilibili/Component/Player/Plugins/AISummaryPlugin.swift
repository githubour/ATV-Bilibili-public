//
//  AISummaryPlugin.swift
//  ATV-Bilibili
//
//  B站官方「AI 视频总结」: 播放器信息面板新增入口,
//  展示 AI 摘要 + 分章大纲, 选中条目跳转到对应时间点。
//

import AVKit
import SnapKit
import UIKit

// MARK: - 数据模型与请求

struct VideoAISummaryResult: Codable {
    struct Outline: Codable {
        struct Part: Codable {
            let timestamp: Int64? // 毫秒
            let content: String?
        }

        let title: String?
        let abstract: String?
        let part_outline: [Part]?
    }

    let summary: String?
    let outline: [Outline]?
}

extension WebRequest {
    static func requestVideoAISummary(aid: Int, cid: Int) async throws -> VideoAISummaryResult {
        struct Resp: Decodable {
            let model_result: VideoAISummaryResult?
        }
        let bvid = BvidConvertor.av2bv(avid: UInt64(aid))
        let resp: Resp = try await request(url: EndPoint.aiConclusion, parameters: ["cid": cid, "bvid": bvid])
        guard let result = resp.model_result else {
            throw RequestError.statusFail(code: 62911, message: "该视频不存在AI总结")
        }
        return result
    }
}

// MARK: - 插件

class AISummaryPlugin: NSObject, CommonPlayerPlugin {
    private let aid: Int
    private let cid: Int
    private weak var playerVC: AVPlayerViewController?
    private weak var player: AVPlayer?

    init(aid: Int, cid: Int) {
        self.aid = aid
        self.cid = cid
        super.init()
    }

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
    }

    func playerDidChange(player: AVPlayer) {
        self.player = player
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        // updateMenus 会整体重建菜单(如换画质换 CDN 时), 每次都要返回入口, 不能只返回一次
        let action = UIAction(title: "AI 视频总结", image: UIImage(systemName: "sparkles")) { [weak self] _ in
            self?.showSummary()
        }
        return [action]
    }

    private func showSummary() {
        Task { @MainActor in
            do {
                let result = try await WebRequest.requestVideoAISummary(aid: aid, cid: cid)
                let vc = AISummaryViewController(summary: result) { seconds in
                    self.player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
                }
                playerVC?.present(vc, animated: true)
            } catch let RequestError.statusFail(code, message) {
                showAlert(title: "AI 视频总结", message: friendlyMessage(code: code, message: message))
            } catch {
                showAlert(title: "AI 视频总结", message: "获取失败：\(error.localizedDescription)")
            }
        }
    }

    private func friendlyMessage(code: Int, message: String) -> String {
        switch code {
        case 62902:
            return "该稿件不支持 AI 总结"
        case 62911:
            return "该视频暂无 AI 总结"
        default:
            return message
        }
    }

    private func showAlert(title: String, message: String) {
        playerVC?.presentAlert(title: title, message: message)
    }
}

// MARK: - 展示页

class AISummaryViewController: UIViewController {
    struct Row {
        let text: String
        let isHeader: Bool
        let timestamp: Double?
    }

    private let rows: [Row]
    private let onSeek: (Double) -> Void
    private var collectionView: UICollectionView!

    init(summary: VideoAISummaryResult, onSeek: @escaping (Double) -> Void) {
        var rows = [Row]()
        if let text = summary.summary, !text.isEmpty {
            rows.append(Row(text: "摘要：\(text)", isHeader: true, timestamp: nil))
        }
        for outline in summary.outline ?? [] {
            let chapterTimestamp = outline.part_outline?.first?.timestamp.map { Double($0) / 1000 }
            if let title = outline.title, !title.isEmpty {
                rows.append(Row(text: title, isHeader: true, timestamp: chapterTimestamp))
            }
            if let parts = outline.part_outline, !parts.isEmpty {
                for part in parts {
                    if let content = part.content, !content.isEmpty {
                        rows.append(Row(text: content, isHeader: false, timestamp: part.timestamp.map { Double($0) / 1000 }))
                    }
                }
            } else if let abstract = outline.abstract, !abstract.isEmpty {
                rows.append(Row(text: abstract, isHeader: false, timestamp: chapterTimestamp))
            }
        }
        self.rows = rows
        self.onSeek = onSeek
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.85)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: createLayout())
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.register(SummaryCell.self)
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.size.equalTo(CGSize(width: 1000, height: 620))
        }

        let closeButton = BLCustomTextButton(frame: .zero)
        closeButton.title = "关闭"
        closeButton.titleColor = .white
        closeButton.onPrimaryAction = { [weak self] _ in
            self?.dismiss(animated: true)
        }
        view.addSubview(closeButton)
        closeButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview().offset(-60)
            make.size.equalTo(CGSize(width: 160, height: 60))
        }

        if rows.isEmpty {
            let label = UILabel()
            label.text = "该视频暂无 AI 总结"
            label.textColor = .white
            label.font = .systemFont(ofSize: 36)
            view.addSubview(label)
            label.snp.makeConstraints { make in
                make.center.equalTo(collectionView.snp.center)
            }
        }
    }

    private func createLayout() -> UICollectionViewLayout {
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .estimated(70))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 14
        section.contentInsets = NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
        return UICollectionViewCompositionalLayout(section: section)
    }
}

extension AISummaryViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeue(SummaryCell.self, for: indexPath)
        let row = rows[indexPath.item]
        cell.configure(text: row.text, isHeader: row.isHeader)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let ts = rows[indexPath.item].timestamp else { return }
        onSeek(ts)
        dismiss(animated: true)
    }
}

private class SummaryCell: BLMotionCollectionViewCell {
    let label = UILabel()

    override func setup() {
        super.setup()
        contentView.addSubview(label)
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 26)
        label.textColor = .white
        label.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20))
        }
        contentView.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        contentView.layer.cornerRadius = 12
        scaleFactor = 1.03
    }

    func configure(text: String, isHeader: Bool) {
        label.text = text
        label.font = isHeader ? .boldSystemFont(ofSize: 30) : .systemFont(ofSize: 26)
    }
}
