//
//  ReplyListFocusGeometryTests.swift
//  ATV-BilibiliTests
//
//  评论区焦点下移失效的几何探针：验证评论列表在高度自适应后，
//  第二行及以后的 cell 仍落在 collectionView 边界内、外层 scrollView 内容可达、cell 可聚焦；
//  楼中楼页重构为「单一纵向列表」后，另验证主评论 cell 按内容撑高、不裁切。
//

@testable import ATV_Bilibili
import UIKit
import XCTest

final class ReplyListFocusGeometryTests: XCTestCase {
    // MARK: - Fixtures

    private func makeReply(message: String, subReplyCount: Int = 0) -> Replys.Reply {
        let subReplies = (0..<subReplyCount).map { i in
            Replys.Reply(
                member: .init(uname: "楼主回复\(i)", avatar: ""),
                content: .init(message: "子回复内容 \(i)", pictures: nil, emote: nil, jump_url: nil),
                replies: nil,
                like: i,
                ctime: 1_700_000_000 + i
            )
        }
        return Replys.Reply(
            member: .init(uname: "用户\(message)", avatar: ""),
            content: .init(message: message, pictures: nil, emote: nil, jump_url: nil),
            replies: subReplies.isEmpty ? nil : subReplies,
            like: 3,
            ctime: 1_700_000_000
        )
    }

    /// 布局跑两轮：第一轮让 reloadData 产生 contentSize，第二轮让 KVO 高度约束落地
    private func settleLayout(in view: UIView) {
        view.layoutIfNeeded()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// CompositionalLayout + estimated 自撑高需要多跑几轮，最后显式 invalidate 让重算后的高度落地
    private func settleSelfSizingLayout(in view: UIView) {
        for _ in 0..<3 {
            view.layoutIfNeeded()
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
        if let cv = firstDescendant(of: UICollectionView.self, in: view) {
            cv.collectionViewLayout.invalidateLayout()
            cv.layoutIfNeeded()
        }
    }

    /// 楼中楼页改为单一 collectionView 后，统一递归查找即可拿到它
    private func firstDescendant<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstDescendant(of: type, in: subview) { return match }
        }
        return nil
    }

    // MARK: - 详情页评论区

    func test_detailPageReplyList_secondRowStaysInsideExpandedCollectionView() throws {
        let storyboard = UIStoryboard(name: "Main", bundle: .main)
        let vc = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "VideoDetailViewController") as? VideoDetailViewController)
        vc.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let window = UIWindow(frame: vc.view.frame)
        window.rootViewController = vc
        window.isHidden = false

        vc.hotReplies = (0..<12).map { makeReply(message: "评论内容第\($0)条") }
        vc.latestReplies = []
        vc.displayedReplies = vc.hotReplies
        vc.hasMoreReplies = false
        vc.updateCommentsTitle()
        vc.replysCollectionView.reloadData()
        settleLayout(in: vc.view)

        let cv: UICollectionView = vc.replysCollectionView

        // 1) 高度自适应：collectionView 必须完全展开到 contentSize，而不是卡在单行 270
        XCTAssertEqual(cv.contentSize.height, cv.frame.size.height, accuracy: 1,
                       "collectionView 高度应与 contentSize 一致（完全展开、不内部滚动）")
        XCTAssertGreaterThan(cv.contentSize.height, 720, "12 条评论（4 列）至少应有 3 行，高度应超过单行 270")

        // 2) 换行方向：第 5 条（index 4）应在第二行（y ≈ 286），而不是被挤去横向一行
        let layout = try XCTUnwrap(cv.collectionViewLayout as? UICollectionViewFlowLayout)
        XCTAssertEqual(layout.scrollDirection, .vertical)
        let attrs3 = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 4, section: 0)))
        XCTAssertGreaterThan(attrs3.frame.minY, 250, "index 4 应换行到第二行，而非横向排开")

        // 3) 第二行 cell 存在、落在 collectionView 边界内、可聚焦
        for index in 4..<8 {
            let indexPath = IndexPath(item: index, section: 0)
            let attrs = try XCTUnwrap(layout.layoutAttributesForItem(at: indexPath))
            XCTAssertLessThanOrEqual(attrs.frame.maxY, cv.bounds.height + 1,
                                     "index \(index) 应在 collectionView 边界内（焦点引擎只认边界内几何）")
            if let cell = cv.cellForItem(at: indexPath) {
                XCTAssertFalse(cell.isHidden, "index \(index) 不应隐藏")
                XCTAssertGreaterThanOrEqual(cell.alpha, 0.99, "index \(index) 不应透明")
                XCTAssertTrue(cell.canBecomeFocused, "index \(index) 应可聚焦")
            }
        }

        // 4) 外层 scrollView：内容必须覆盖到评论区底部（focus 下移时系统靠它滚动）
        let scrollView: UIScrollView = try XCTUnwrap(vc.scrollView)
        let cvFrameInScroll = vc.view.convert(cv.frame, to: scrollView)
        XCTAssertLessThanOrEqual(cvFrameInScroll.maxY, scrollView.contentSize.height + 1,
                                 "评论区底部必须落在 scrollView contentSize 内")
        XCTAssertGreaterThan(scrollView.contentSize.height, scrollView.frame.height,
                             "详情页内容应超出一屏（否则下移无处可去）")
    }

    // MARK: - 楼中楼页（单一纵向列表）

    func test_replyDetailPage_singleCollectionViewReachesAllSubReplies() throws {
        let reply = makeReply(message: "主评论", subReplyCount: 9)
        let vc = ReplyDetailViewController(reply: reply)
        vc.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let window = UIWindow(frame: vc.view.frame)
        window.rootViewController = vc
        window.isHidden = false
        settleSelfSizingLayout(in: vc.view)

        let contentView = try XCTUnwrap(vc.view.subviews.first)

        // 1) 单一滚动容器：contentView 直接子视图里只有一个 UICollectionView，不再有平级的主评论 UIScrollView
        let scrollChildren = contentView.subviews.filter { $0 is UIScrollView }
        XCTAssertEqual(scrollChildren.count, 1, "整页应只有一个滚动容器（单一 collectionView）")
        let cv = try XCTUnwrap(scrollChildren.first as? UICollectionView)
        XCTAssertTrue(cv.isScrollEnabled)
        XCTAssertTrue(cv.collectionViewLayout is UICollectionViewCompositionalLayout)

        // 2) 两 section：主评论 1 条 + 子评论 9 条
        XCTAssertEqual(vc.numberOfSections(in: cv), 2)
        XCTAssertEqual(vc.collectionView(cv, numberOfItemsInSection: 0), 1)
        XCTAssertEqual(vc.collectionView(cv, numberOfItemsInSection: 1), 9)

        // 3) 全宽单列：各行等宽、minY 逐行递增
        let layout = cv.collectionViewLayout
        var widths = Set<CGFloat>()
        var previousMinY: CGFloat = -.infinity
        for index in 0..<9 {
            let attrs = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: index, section: 1)))
            widths.insert(attrs.frame.width.rounded())
            XCTAssertGreaterThan(attrs.frame.minY, previousMinY, "index \(index) 应逐行下移（单列）")
            previousMinY = attrs.frame.minY
        }
        XCTAssertEqual(widths.count, 1, "全宽单列：所有子评论行应等宽")
        XCTAssertEqual(widths.first ?? 0, (contentView.bounds.width - 120).rounded(), accuracy: 2,
                       "行宽应为全宽减左右各 60 inset")

        // 4) 9 条内容超出一屏、所有行落在内容区内；已显示（非 hidden）的 cell 必须可聚焦
        // （屏幕外预取的 cell 会带 isHidden，跳过即可，不拿它断言）
        XCTAssertGreaterThan(cv.contentSize.height, cv.frame.height)
        for index in 0..<9 {
            let indexPath = IndexPath(item: index, section: 1)
            let attrs = try XCTUnwrap(layout.layoutAttributesForItem(at: indexPath))
            XCTAssertLessThanOrEqual(attrs.frame.maxY, cv.contentSize.height + 1, "行 \(index) 应落在内容区内")
            if let cell = cv.cellForItem(at: indexPath), !cell.isHidden {
                XCTAssertTrue(cell.canBecomeFocused, "index \(index) 应可聚焦")
            }
        }
    }

    func test_replyDetailPage_mainReplyExpandsWithContentWithoutClipping() throws {
        // 短主评论 / 超长主评论两种极端，主评论 cell 都应随文本撑高，而不是被固定高度裁切
        var mainHeights: [CGFloat] = []
        for message in ["短评", String(repeating: "长评论", count: 3000)] {
            let reply = makeReply(message: message, subReplyCount: 2)
            let vc = ReplyDetailViewController(reply: reply)
            vc.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

            let window = UIWindow(frame: vc.view.frame)
            window.rootViewController = vc
            window.isHidden = false
            settleSelfSizingLayout(in: vc.view)

            let cv = try XCTUnwrap(firstDescendant(of: UICollectionView.self, in: vc.view))
            let layout = cv.collectionViewLayout
            let mainAttrs = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
            let firstSubAttrs = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 1)))
            let secondSubAttrs = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 1)))
            mainHeights.append(mainAttrs.frame.height)
            XCTAssertGreaterThan(mainAttrs.frame.height, 150, "主评论 cell 不应被压缩塌掉")

            // 1) 主评论与子评论首行间距恒定 20（interSectionSpacing）
            XCTAssertEqual(firstSubAttrs.frame.minY - mainAttrs.frame.maxY, 20, accuracy: 2,
                           "主评论与子评论间距应保持 20pt")
            // 2) 子评论行不再是被撑满的 360pt 固定卡
            XCTAssertLessThan(secondSubAttrs.frame.height, 360, "子评论行不应再是固定 360pt 卡")
            // 3) 主评论 cell 完整可见、可聚焦
            if let cell = cv.cellForItem(at: IndexPath(item: 0, section: 0)) {
                XCTAssertFalse(cell.isHidden)
                XCTAssertTrue(cell.canBecomeFocused)
            }
        }
        XCTAssertGreaterThan(mainHeights[1], mainHeights[0], "长主评论应把 cell 撑高，而不是被裁掉")
        // 绝对下限：防住「只比短评高一点、但仍停在三行左右」的半撑开状态
        XCTAssertGreaterThan(mainHeights[1], 600, "超长主评论应撑到远超三行，而不是仍被省略号截断")
    }

    func test_replyDetailPage_longSubReplyExpandsCellWithoutTruncation() throws {
        // 子评论特别长时，cell 必须完整撑开，不能停在三行后显示省略号
        let longMessage = String(repeating: "这是一段很长的子评论内容需要完整显示", count: 80)
        let sub = Replys.Reply(
            member: .init(uname: "回复者", avatar: ""),
            content: .init(message: longMessage, pictures: nil, emote: nil, jump_url: nil),
            replies: nil,
            like: 1,
            ctime: 1_700_000_000
        )
        let reply = Replys.Reply(
            member: .init(uname: "楼主", avatar: ""),
            content: .init(message: "主评论", pictures: nil, emote: nil, jump_url: nil),
            replies: [sub],
            like: 3,
            ctime: 1_700_000_000
        )
        let vc = ReplyDetailViewController(reply: reply)
        vc.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let window = UIWindow(frame: vc.view.frame)
        window.rootViewController = vc
        window.isHidden = false
        settleSelfSizingLayout(in: vc.view)

        let cv = try XCTUnwrap(firstDescendant(of: UICollectionView.self, in: vc.view))
        let attrs = try XCTUnwrap(cv.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 0, section: 1)))
        // 约 1400 字在全宽下需二十余行；若只撑到三行（约 240pt）就会失败
        XCTAssertGreaterThan(attrs.frame.height, 600,
                             "超长子评论应把 cell 撑到完整高度，而不是三行后省略")
    }
}
