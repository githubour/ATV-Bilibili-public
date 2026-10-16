//
//  ReusableView.swift
//  ATV-Bilibili
//
//  用类型本身作为复用标识符，避免散落的 "cell" 字面量与 dequeue 后的 as! 强转。
//

import UIKit

protocol BLReusableView: AnyObject {
    static var reuseIdentifier: String { get }
}

extension BLReusableView {
    static var reuseIdentifier: String { String(describing: Self.self) }
}

// UICollectionReusableView 默认按类名作为复用标识符，UICollectionViewCell 继承自它，无需逐个声明
extension UICollectionReusableView: BLReusableView {}

extension UICollectionView {
    func register<T: UICollectionViewCell>(_ cellClass: T.Type) where T: BLReusableView {
        register(cellClass, forCellWithReuseIdentifier: T.reuseIdentifier)
    }

    func dequeue<T: UICollectionViewCell>(_ cellClass: T.Type, for indexPath: IndexPath) -> T where T: BLReusableView {
        guard let cell = dequeueReusableCell(withReuseIdentifier: T.reuseIdentifier, for: indexPath) as? T else {
            fatalError("未注册 cell: \(T.reuseIdentifier)")
        }
        return cell
    }

    func register<T: UICollectionReusableView>(_ viewClass: T.Type, forSupplementaryViewOfKind kind: String) where T: BLReusableView {
        register(viewClass, forSupplementaryViewOfKind: kind, withReuseIdentifier: T.reuseIdentifier)
    }

    func dequeue<T: UICollectionReusableView>(_ viewClass: T.Type, ofKind kind: String, for indexPath: IndexPath) -> T where T: BLReusableView {
        guard let view = dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: T.reuseIdentifier, for: indexPath) as? T else {
            fatalError("未注册 supplementary view: \(T.reuseIdentifier)")
        }
        return view
    }
}
