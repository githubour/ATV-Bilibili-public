//
//  Int+Extensions.swift
//  ATV-Bilibili
//
//  Created by whw on 2022/11/4.
//

import Foundation

extension Int {
    func numberString() -> String {
        if self > 10000 {
            return String(format: "%.1f 万", floor(Double(self) / 1000) / 10)
        }
        return String(self)
    }
}
