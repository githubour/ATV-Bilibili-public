//
//  MaskProvider.swift
//  ATV-Bilibili
//
//  Created by yicheng on 2024/6/10.
//
import AVKit

protocol MaskProvider: AnyObject {
    func getMask(for time: CMTime, frame: CGRect, onGet: @escaping (CALayer) -> Void)
    func preferFPS() -> Int
}
